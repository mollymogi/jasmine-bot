import Foundation

/// Incremental Server-Sent Events (SSE) frame parser shared between live stream & unit tests.
public struct SSEFrameParser: Sendable {
    private var buffer = ""
    private var currentEvent = "message"
    private var currentDataLines: [String] = []

    public init() {}

    public mutating func feed(_ chunk: String) -> [(event: String, data: String)] {
        buffer += chunk.replacingOccurrences(of: "\r\n", with: "\n")
        var emitted: [(String, String)] = []
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[..<newlineRange.lowerBound])
            buffer.removeSubrange(..<newlineRange.upperBound)
            if line.isEmpty {
                if !currentDataLines.isEmpty {
                    emitted.append((currentEvent, currentDataLines.joined(separator: "\n")))
                }
                currentEvent = "message"
                currentDataLines.removeAll(keepingCapacity: true)
            } else if line.hasPrefix(":") {
                continue
            } else if line.hasPrefix("event:") {
                currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                var val = String(line.dropFirst(5))
                if val.hasPrefix(" ") { val.removeFirst() }
                currentDataLines.append(val)
            }
        }
        return emitted
    }

    public static func decodeEvent(name: String, data: String) -> MobileSSEEvent? {
        guard let raw = data.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        switch name {
        case "bootstrap":
            if let boot = try? decoder.decode(MobileBootstrapResponse.self, from: raw) {
                return .bootstrap(boot)
            }
        case "rooms_updated":
            struct RoomsEnvelope: Decodable { let rooms: [ChatRoomSummary] }
            if let env = try? decoder.decode(RoomsEnvelope.self, from: raw) {
                return .roomsUpdated(env.rooms)
            }
        case "approvals_updated":
            struct ApprovalsEnvelope: Decodable { let approvals: [ApprovalItem] }
            if let env = try? decoder.decode(ApprovalsEnvelope.self, from: raw) {
                return .approvalsUpdated(env.approvals)
            }
        case "ping", "connected":
            return .ping
        default:
            break
        }
        return nil
    }
}

public actor JasmineAPIClient {
    private var credentials: StoredCredentials?
    private let racer: RouteRacer
    private let urlSession: URLSession

    public init(credentials: StoredCredentials? = nil, racer: RouteRacer = RouteRacer(), urlSession: URLSession? = nil) {
        self.credentials = credentials
        self.racer = racer
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 300
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
            self.urlSession = URLSession(configuration: cfg)
        }
    }

    public func updateCredentials(_ next: StoredCredentials?) async {
        self.credentials = next
        await racer.clearCache()
    }

    public func activeRouteOutcome() async -> RouteProbeOutcome? {
        await racer.currentRoute()
    }

    // MARK: - Pairing (QR Multi-Route or Manual Host + 6-digit PIN)

    public func pairWithQR(qrString: String, deviceLabel: String = "iPhone · Jasmine Bot") async throws -> StoredCredentials {
        let bundle = try MobilePairingBundle.parse(qrString: qrString)
        let probeWinner = try await racer.selectBestRoute(candidates: bundle.routes, sessionToken: nil)
        return try await performPairRequest(
            origin: probeWinner.endpoint.origin,
            fallbackRoutes: bundle.routes,
            body: ["token": bundle.pairingToken, "deviceLabel": deviceLabel]
        )
    }

    public func pairWithPIN(
        rawOrigin: String,
        pin: String,
        extraTunnelOrigin: String? = nil,
        deviceLabel: String = "iPhone · Jasmine Bot"
    ) async throws -> StoredCredentials {
        let primary = RouteEndpoint(
            kind: rawOrigin.lowercased().hasPrefix("https") ? .tunnel : (rawOrigin.contains("100.") ? .tailscale : .lan),
            origin: rawOrigin
        )
        var candidates = [primary]
        if let extra = extraTunnelOrigin, !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(RouteEndpoint(kind: .tunnel, origin: extra))
        }
        let winner = try await racer.selectBestRoute(candidates: candidates, sessionToken: nil)
        let cleanPin = pin.replacingOccurrences(of: " ", with: "")
        return try await performPairRequest(
            origin: winner.endpoint.origin,
            fallbackRoutes: candidates,
            body: ["pin": cleanPin, "deviceLabel": deviceLabel]
        )
    }

    private func performPairRequest(
        origin: String,
        fallbackRoutes: [RouteEndpoint],
        body: [String: String]
    ) async throws -> StoredCredentials {
        guard let url = URL(string: "\(origin)/api/remote/pair") else {
            throw JasmineClientError.invalidPairingCode("服务器地址格式错误")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ios-native", forHTTPHeaderField: "X-Jasmine-Client")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw JasmineClientError.serverError(0, "配对请求无响应")
        }
        struct PairReply: Decodable {
            struct DeviceObj: Decodable { let id: String }
            let ok: Bool?
            let sessionToken: String?
            let hostLabel: String?
            let device: DeviceObj?
            let routes: [RouteEndpoint]?
            let error: String?
        }
        let decoded = try? JSONDecoder().decode(PairReply.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            throw JasmineClientError.serverError(http.statusCode, decoded?.error ?? "配对失败 (HTTP \(http.statusCode))")
        }
        let token = decoded?.sessionToken ?? Self.extractSessionTokenFromSetCookie(http)
        guard let token, !token.isEmpty else {
            throw JasmineClientError.serverError(500, "服务端未返回配对会话凭证")
        }
        let mergedRoutes = RouteRacer.orderedUniqueRoutes((decoded?.routes ?? []) + fallbackRoutes)
        let creds = StoredCredentials(
            hostLabel: decoded?.hostLabel ?? URL(string: origin)?.host ?? "Jasmine Bot",
            sessionToken: token,
            deviceId: decoded?.device?.id,
            routes: mergedRoutes,
            preferredOrigin: origin
        )
        self.credentials = creds
        return creds
    }

    private static func extractSessionTokenFromSetCookie(_ http: HTTPURLResponse) -> String? {
        for (k, v) in http.allHeaderFields {
            guard String(describing: k).lowercased() == "set-cookie" else { continue }
            let raw = String(describing: v)
            if let range = raw.range(of: "jasmine_studio_session=") {
                let tail = raw[range.upperBound...]
                let token = tail.prefix { $0 != ";" && $0 != "," }
                return String(token).removingPercentEncoding ?? String(token)
            }
        }
        return nil
    }

    // MARK: - Authenticated Request Helper with Automatic Multi-Route Failover

    private func resolveOrigin(forceReprobe: Bool = false) async throws -> String {
        guard let creds = credentials else {
            throw JasmineClientError.unauthorized
        }
        if !forceReprobe, let cached = await racer.currentRoute() {
            return cached.endpoint.origin
        }
        let best = try await racer.selectBestRoute(candidates: creds.routes, sessionToken: creds.sessionToken)
        return best.endpoint.origin
    }

    public func reraceRoutes() async throws -> RouteProbeOutcome {
        guard let creds = credentials else { throw JasmineClientError.unauthorized }
        await racer.clearCache()
        return try await racer.selectBestRoute(candidates: creds.routes, sessionToken: creds.sessionToken)
    }

    private func authorizedRequest(
        path: String,
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        rawBody: Data? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        guard let creds = credentials else { throw JasmineClientError.unauthorized }
        for attempt in 0..<2 {
            let origin = try await resolveOrigin(forceReprobe: attempt > 0)
            guard let url = URL(string: "\(origin)\(path)") else {
                throw JasmineClientError.serverError(400, "无效的接口路径：\(path)")
            }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(creds.sessionToken)", forHTTPHeaderField: "Authorization")
            req.setValue("ios-native", forHTTPHeaderField: "X-Jasmine-Client")
            req.setValue(origin, forHTTPHeaderField: "Origin")
            if let jsonBody {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            } else if let rawBody {
                req.httpBody = rawBody
            }
            for (hk, hv) in extraHeaders {
                req.setValue(hv, forHTTPHeaderField: hk)
            }
            do {
                let (data, resp) = try await urlSession.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if http.statusCode == 401 {
                    throw JasmineClientError.unauthorized
                }
                guard (200..<300).contains(http.statusCode) else {
                    let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    throw JasmineClientError.serverError(http.statusCode, msg ?? "请求失败 (\(http.statusCode))")
                }
                return data
            } catch let err as JasmineClientError {
                throw err
            } catch {
                if attempt == 0 && creds.routes.count > 1 {
                    await racer.clearCache()
                    continue
                }
                throw error
            }
        }
        throw JasmineClientError.allRoutesUnreachable(creds.routes.map(\.origin))
    }

    // MARK: - Core Mobile Operations

    public func fetchBootstrap() async throws -> MobileBootstrapResponse {
        let data = try await authorizedRequest(path: "/api/mobile/bootstrap")
        return try JSONDecoder().decode(MobileBootstrapResponse.self, from: data)
    }

    public func executionDevices() async throws -> [BotExecutionDevice] {
        async let primaryResponse = authorizedRequest(path: "/api/chatrooms/catalog")
        async let nodesResponse = authorizedRequest(path: "/api/worker-nodes")
        let (primary, nodes) = try await (primaryResponse, nodesResponse)
        return try BotExecutionDevice.decodeInventories(primary: primary, workers: nodes)
    }

    public func createBot(_ draft: BotCreationRequest) async throws -> ChatRoomSummary {
        do {
            let data = try await authorizedRequest(path: "/api/chatrooms", method: "POST", jsonBody: draft.payload)
            return try JSONDecoder().decode(ChatRoomSummary.self, from: data)
        } catch JasmineClientError.serverError(409, _) {
            // The first route can accept a POST before its response is lost.
            let data = try await authorizedRequest(path: "/api/chatrooms/\(draft.id)?slim=1&limit=1")
            let existing = try JSONDecoder().decode(ChatRoomSummary.self, from: data)
            guard draft.matches(existing) else { throw JasmineClientError.serverError(409, "会话已存在，请重新打开创建窗口") }
            return existing
        }
    }

    public func fetchRoom(roomId: String, limit: Int = 80) async throws -> ChatRoomDetail {
        let data = try await authorizedRequest(path: "/api/chatrooms/\(roomId)?slim=1&limit=\(limit)")
        return try JSONDecoder().decode(ChatRoomDetail.self, from: data)
    }

    public func sendMessage(roomId: String, text: String, attachmentPaths: [String] = []) async throws {
        var payload: [String: Any] = ["text": text]
        if !attachmentPaths.isEmpty {
            payload["referenceFilePaths"] = attachmentPaths
        }
        _ = try await authorizedRequest(
            path: "/api/chatrooms/\(roomId)/messages",
            method: "POST",
            jsonBody: payload
        )
    }

    public func fetchRoomMediaData(roomId: String, filePath: String, thumbnail: Bool = false, maxWidth: Int = 720) async throws -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? filePath
        let thumbQuery = thumbnail ? "&thumb=1&w=\(maxWidth)" : ""
        return try await authorizedRequest(path: "/api/chatrooms/\(roomId)/file-raw?path=\(encodedPath)\(thumbQuery)")
    }

    public func resolveRoomMediaStreamInfo(roomId: String, filePath: String) async throws -> (url: URL, headers: [String: String]) {
        guard let creds = credentials else { throw JasmineClientError.unauthorized }
        let origin = try await resolveOrigin()
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? filePath
        guard let url = URL(string: "\(origin)/api/chatrooms/\(roomId)/file-raw?path=\(encodedPath)") else {
            throw JasmineClientError.serverError(400, "无效的媒体地址")
        }
        return (
            url: url,
            headers: [
                "Authorization": "Bearer \(creds.sessionToken)",
                "Origin": origin
            ]
        )
    }

    public func uploadAttachment(roomId: String, filename: String, mimeType: String, fileData: Data) async throws -> String {
        let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "upload.bin"
        let data = try await authorizedRequest(
            path: "/api/chatrooms/\(roomId)/attachments?name=\(encodedName)",
            method: "POST",
            rawBody: fileData,
            extraHeaders: [
                "Content-Type": mimeType,
                "X-File-Mime": mimeType,
                "X-File-Name": encodedName
            ]
        )
        struct UploadReply: Decodable { let path: String? }
        let reply = try JSONDecoder().decode(UploadReply.self, from: data)
        guard let savedPath = reply.path, !savedPath.isEmpty else {
            throw JasmineClientError.serverError(500, "附件上传未返回路径")
        }
        return savedPath
    }

    public func stopRoom(roomId: String) async throws {
        _ = try await authorizedRequest(
            path: "/api/chatrooms/\(roomId)/stop",
            method: "POST",
            jsonBody: [:]
        )
    }

    public func decideApproval(reviewId: String, mode: ApprovalDecisionMode, reason: String? = nil) async throws {
        var body: [String: Any] = ["decision": mode.rawValue]
        if let reason, !reason.isEmpty {
            body["reason"] = reason
        }
        _ = try await authorizedRequest(
            path: "/api/mobile/approvals/\(reviewId)/decide",
            method: "POST",
            jsonBody: body
        )
    }

    public func fetchRoomTerminalSnapshot(roomId: String, lines: Int = 120) async throws -> String {
        let data = try await authorizedRequest(path: "/api/chatrooms/\(roomId)/details?lines=\(lines)")
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let term = obj["terminalText"] as? String, !term.isEmpty { return term }
            if let panes = obj["panes"] as? [[String: Any]], let first = panes.first?["snapshot"] as? String {
                return first
            }
        }
        return "当前没有正在输出的实时终端画面。"
    }

    // MARK: - Live SSE Event Stream

    public func eventStream() -> AsyncThrowingStream<MobileSSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let creds = self.credentials else {
                    continuation.finish(throwing: JasmineClientError.unauthorized)
                    return
                }
                do {
                    let origin = try await self.resolveOrigin()
                    guard let url = URL(string: "\(origin)/api/mobile/events") else { return }
                    var req = URLRequest(url: url)
                    req.setValue("Bearer \(creds.sessionToken)", forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 3600

                    let (bytes, resp) = try await self.urlSession.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                        if (resp as? HTTPURLResponse)?.statusCode == 401 {
                            continuation.finish(throwing: JasmineClientError.unauthorized)
                        } else {
                            continuation.finish(throwing: URLError(.badServerResponse))
                        }
                        return
                    }
                    var parser = SSEFrameParser()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        let frames = parser.feed(line + "\n")
                        for frame in frames {
                            if let evt = SSEFrameParser.decodeEvent(name: frame.event, data: frame.data) {
                                continuation.yield(evt)
                            }
                        }
                        // Blank line separator in URLSession.AsyncBytes.lines is skipped by `.lines`,
                        // so if `data:` arrived as a single JSON line, flush immediately:
                        if line.hasPrefix("data:") {
                            for frame in parser.feed("\n") {
                                if let evt = SSEFrameParser.decodeEvent(name: frame.event, data: frame.data) {
                                    continuation.yield(evt)
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
