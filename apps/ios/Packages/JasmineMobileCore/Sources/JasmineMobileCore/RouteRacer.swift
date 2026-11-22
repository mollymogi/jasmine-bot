import Foundation

public struct RouteProbeOutcome: Sendable, Equatable {
    public let endpoint: RouteEndpoint
    public let latencyMs: Int
    public let authenticated: Bool

    public init(endpoint: RouteEndpoint, latencyMs: Int, authenticated: Bool) {
        self.endpoint = endpoint
        self.latencyMs = latencyMs
        self.authenticated = authenticated
    }
}

public typealias RouteProbeHandler = @Sendable (RouteEndpoint, String?) async throws -> RouteProbeOutcome

/// Races multiple host routes (Home Wi-Fi LAN, Cloudflare Public HTTPS Tunnel, Tailscale)
/// so iPhone automatically uses 2ms LAN at home and seamlessly switches to 5G HTTPS Tunnel outdoors without VPN.
public actor RouteRacer {
    private let probeHandler: RouteProbeHandler
    private var activeOutcome: RouteProbeOutcome?

    public init(probeHandler: RouteProbeHandler? = nil) {
        self.probeHandler = probeHandler ?? Self.defaultHTTPProbe
    }

    public func currentRoute() -> RouteProbeOutcome? {
        activeOutcome
    }

    public func clearCache() {
        activeOutcome = nil
    }

    public func selectBestRoute(
        candidates: [RouteEndpoint],
        sessionToken: String?
    ) async throws -> RouteProbeOutcome {
        let deduplicated = Self.orderedUniqueRoutes(candidates)
        guard !deduplicated.isEmpty else {
            throw JasmineClientError.allRoutesUnreachable([])
        }

        let probe = self.probeHandler
        var sawUnauthorized = false

        let winner: RouteProbeOutcome? = await withTaskGroup(of: Result<RouteProbeOutcome, Error>.self) { group in
            for route in deduplicated {
                group.addTask {
                    // Give LAN a tiny head start over internet tunnels when both are reachable,
                    // while still racing in parallel so dead LAN on 5G adds zero delay!
                    if route.kind != .lan && deduplicated.contains(where: { $0.kind == .lan }) {
                        try? await Task.sleep(nanoseconds: 80_000_000) // 80ms preference window for LAN
                    }
                    do {
                        let res = try await probe(route, sessionToken)
                        return .success(res)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            while let next = await group.next() {
                switch next {
                case .success(let outcome):
                    if sessionToken != nil && !outcome.authenticated {
                        sawUnauthorized = true
                        continue
                    }
                    group.cancelAll()
                    return outcome
                case .failure(let err):
                    if let clientErr = err as? JasmineClientError, clientErr == .unauthorized {
                        sawUnauthorized = true
                    }
                }
            }
            return nil
        }

        if let winner {
            self.activeOutcome = winner
            return winner
        }
        if sawUnauthorized {
            throw JasmineClientError.unauthorized
        }
        throw JasmineClientError.allRoutesUnreachable(deduplicated.map(\.origin))
    }

    public static func orderedUniqueRoutes(_ routes: [RouteEndpoint]) -> [RouteEndpoint] {
        var seen = Set<String>()
        var unique: [RouteEndpoint] = []
        for r in routes where !r.origin.isEmpty {
            let key = r.origin.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(r)
            }
        }
        return unique.sorted { a, b in
            if a.kind.priorityRank != b.kind.priorityRank {
                return a.kind.priorityRank < b.kind.priorityRank
            }
            return a.origin < b.origin
        }
    }

    public static let defaultHTTPProbe: RouteProbeHandler = { endpoint, sessionToken in
        guard let url = URL(string: "\(endpoint.origin)/api/remote/auth") else {
            throw JasmineClientError.invalidPairingCode("无效的地址：\(endpoint.origin)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = endpoint.kind == .lan ? 1.6 : 4.0
        if let token = sessionToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("ios-native", forHTTPHeaderField: "X-Jasmine-Client")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        let start = ContinuousClock.now
        let (data, resp) = try await session.data(for: req)
        let elapsed = start.duration(to: ContinuousClock.now)
        let ms = max(1, Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))

        guard let http = resp as? HTTPURLResponse else {
            throw JasmineClientError.serverError(0, "无响应")
        }
        if http.statusCode == 401 {
            throw JasmineClientError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JasmineClientError.serverError(http.statusCode, "HTTP \(http.statusCode)")
        }
        struct AuthProbeReply: Decodable {
            let authenticated: Bool?
            let requiresAuth: Bool?
        }
        let decoded = try? JSONDecoder().decode(AuthProbeReply.self, from: data)
        let authed = decoded?.authenticated ?? (decoded?.requiresAuth == false)
        return RouteProbeOutcome(endpoint: endpoint, latencyMs: ms, authenticated: authed)
    }
}
