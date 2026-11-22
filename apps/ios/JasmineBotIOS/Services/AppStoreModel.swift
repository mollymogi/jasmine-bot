import Foundation
import Network
import UserNotifications
import Observation
import JasmineMobileCore

@Observable
@MainActor
public final class AppStoreModel {
    public enum TabSelection: Hashable {
        case chats
        case approvals
        case voice
        case host
    }

    public var selectedTab: TabSelection = .chats
    public var selectedRoomId: String?
    public var credentials: StoredCredentials?
    public var activeRoute: RouteProbeOutcome?
    public var isConnecting = false
    public var connectionError: String?

    public var hostSummary: HostStatusSummary?
    public var rooms: [ChatRoomSummary] = []
    public var approvals: [ApprovalItem] = []
    public var quotas: [QuotaSummaryItem] = []
    public var workerNodes: [WorkerNodeSummary] = []

    public let client = JasmineAPIClient()
    public let speech = SpeechService()

    private var sseTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.jasmine.bot.ios.netmonitor")
    private var previousBusyMap: [String: Bool] = [:]
    private var knownApprovalIds = Set<String>()

    public init() {
        if let saved = KeychainStore.load() {
            self.credentials = saved
            Task {
                await client.updateCredentials(saved)
                await refreshAll()
                startEventStream()
            }
        }
        startNetworkPathWatcher()
        requestNotificationPermission()
    }

    private nonisolated func startNetworkPathWatcher() {
        let monitor = self.pathMonitor
        let queue = self.monitorQueue
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, self.credentials != nil else { return }
                await self.reraceRoutesSilently()
            }
        }
        monitor.start(queue: queue)
    }

    private nonisolated func requestNotificationPermission() {
        Task.detached {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        }
    }

    // MARK: - Pairing & Sign Out

    public func handleDeepLink(_ url: URL) async {
        await pairWithQR(url.absoluteString)
    }

    public func pairWithQR(_ raw: String) async {
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }
        do {
            let creds = try await client.pairWithQR(qrString: raw)
            KeychainStore.save(creds)
            self.credentials = creds
            self.activeRoute = await client.activeRouteOutcome()
            await refreshAll()
            startEventStream()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    public func pairWithPIN(origin: String, pin: String, tunnelOrigin: String) async {
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }
        do {
            let creds = try await client.pairWithPIN(
                rawOrigin: origin,
                pin: pin,
                extraTunnelOrigin: tunnelOrigin.isEmpty ? nil : tunnelOrigin
            )
            KeychainStore.save(creds)
            self.credentials = creds
            self.activeRoute = await client.activeRouteOutcome()
            await refreshAll()
            startEventStream()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    public func addOrUpdateTunnelRoute(_ tunnelUrl: String) async {
        guard var creds = credentials else { return }
        let normalized = RouteEndpoint.normalizeOrigin(tunnelUrl)
        guard !normalized.isEmpty else { return }
        var filtered = creds.routes.filter { $0.kind != .tunnel }
        filtered.append(RouteEndpoint(kind: .tunnel, origin: normalized))
        creds.routes = RouteRacer.orderedUniqueRoutes(filtered)
        KeychainStore.save(creds)
        self.credentials = creds
        await client.updateCredentials(creds)
        await reraceRoutesSilently()
    }

    public func signOut() async {
        sseTask?.cancel()
        sseTask = nil
        KeychainStore.clear()
        credentials = nil
        activeRoute = nil
        rooms = []
        approvals = []
        quotas = []
        workerNodes = []
        await client.updateCredentials(nil)
    }

    // MARK: - Bootstrap & Live SSE Sync

    public func reraceRoutesSilently() async {
        do {
            let winner = try await client.reraceRoutes()
            self.activeRoute = winner
            self.connectionError = nil
        } catch JasmineClientError.unauthorized {
            await signOut()
            self.connectionError = "远程授权已过期，请重新扫码配对"
        } catch {
            self.connectionError = error.localizedDescription
        }
    }

    public func refreshAll() async {
        guard credentials != nil else { return }
        do {
            let boot = try await client.fetchBootstrap()
            applyBootstrap(boot)
            self.activeRoute = await client.activeRouteOutcome()
            self.connectionError = nil
        } catch JasmineClientError.unauthorized {
            await signOut()
            self.connectionError = "配对已失效，请重新扫码或输入 PIN"
        } catch {
            self.connectionError = error.localizedDescription
        }
    }

    private func applyBootstrap(_ boot: MobileBootstrapResponse) {
        self.hostSummary = boot.host
        updateRoomsWithNotifications(boot.rooms)
        updateApprovalsWithNotifications(boot.approvals)
        self.quotas = boot.quotas
        self.workerNodes = boot.workerNodes

        // Merge any newly discovered host routes (e.g. host turned on cloudflared tunnel after pairing!)
        if var creds = credentials, let serverRoutes = boot.host.routes, !serverRoutes.isEmpty {
            let merged = RouteRacer.orderedUniqueRoutes(creds.routes + serverRoutes)
            if merged != creds.routes {
                creds.routes = merged
                self.credentials = creds
                KeychainStore.save(creds)
                Task { await client.updateCredentials(creds) }
            }
        }
    }

    public func startEventStream() {
        sseTask?.cancel()
        guard credentials != nil else { return }
        sseTask = Task {
            while !Task.isCancelled && self.credentials != nil {
                do {
                    for try await event in await client.eventStream() {
                        switch event {
                        case .bootstrap(let boot):
                            applyBootstrap(boot)
                            self.activeRoute = await client.activeRouteOutcome()
                        case .roomsUpdated(let nextRooms):
                            updateRoomsWithNotifications(nextRooms)
                        case .approvalsUpdated(let nextApprovals):
                            updateApprovalsWithNotifications(nextApprovals)
                        case .ping:
                            break
                        }
                    }
                } catch JasmineClientError.unauthorized {
                    await signOut()
                    break
                } catch {
                    // Network switched (e.g. Wi-Fi -> 5G): re-race routes & reconnect after short backoff
                    await reraceRoutesSilently()
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                }
            }
        }
    }

    // MARK: - Local Notifications on Long-Task Completion & New Approvals

    private func updateRoomsWithNotifications(_ nextRooms: [ChatRoomSummary]) {
        for room in nextRooms {
            let wasBusy = previousBusyMap[room.id] ?? false
            let nowBusy = room.busy ?? false
            if wasBusy && !nowBusy {
                postLocalNotification(
                    title: "任务已完成 · \(room.title)",
                    body: "点击查看 Bot 最新执行结果",
                    userInfo: ["roomId": room.id]
                )
            }
            previousBusyMap[room.id] = nowBusy
        }
        self.rooms = nextRooms.filter { $0.archived != true }
    }

    private func updateApprovalsWithNotifications(_ nextApprovals: [ApprovalItem]) {
        let initialized = !knownApprovalIds.isEmpty || !approvals.isEmpty
        for item in nextApprovals where !knownApprovalIds.contains(item.id) {
            knownApprovalIds.insert(item.id)
            if initialized {
                postLocalNotification(
                    title: "待你审批 · \(item.title)",
                    body: item.detail.isEmpty ? "Bot 正在等待你的确认（允许 / 拒绝）" : String(item.detail.prefix(80)),
                    userInfo: ["approvalId": item.id]
                )
            }
        }
        self.approvals = nextApprovals
    }

    private func postLocalNotification(title: String, body: String, userInfo: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    public func decideApproval(_ item: ApprovalItem, mode: ApprovalDecisionMode) async {
        do {
            try await client.decideApproval(reviewId: item.id, mode: mode)
            approvals.removeAll { $0.id == item.id }
        } catch {
            connectionError = error.localizedDescription
        }
    }
}
