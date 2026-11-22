import Foundation
import JasmineMobileCore

@main
struct JasmineMobileCoreCheck {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("❌ Assertion failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func main() async throws {
        // 1. Multi-route QR deep link round-trip
        let original = MobilePairingBundle(
            version: 1,
            hostName: "mercuryliumac-mini.local",
            pairingToken: "tok_secret_123456",
            routes: [
                RouteEndpoint(kind: .lan, label: "局域网", origin: "http://192.168.3.159:4319"),
                RouteEndpoint(kind: .tunnel, label: "公网 HTTPS", origin: "https://bot.example.com"),
                RouteEndpoint(kind: .tailscale, label: "Tailscale", origin: "http://100.94.63.125:4319")
            ]
        )
        let json = try JSONEncoder().encode(original)
        let b64url = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let parsed = try MobilePairingBundle.parse(qrString: "jasminebot://pair?data=\(b64url)")
        check(parsed.hostName == "mercuryliumac-mini.local", "hostName match")
        check(parsed.pairingToken == "tok_secret_123456", "token match")
        check(parsed.routes.count == 3 && parsed.routes[1].kind == .tunnel, "routes match")

        // 2. Web QR URL with embedded &routes=
        let webUrl = "https://bot.example.com/?pair=tok_secret_123456&routes=\(b64url)#chatrooms"
        let parsedWeb = try MobilePairingBundle.parse(qrString: webUrl)
        check(parsedWeb.routes.count == 3, "embedded web routes match")

        // 3. RouteRacer: 5G outdoor (LAN unreachable -> HTTPS Tunnel wins over slow Tailscale)
        let outdoorRacer = RouteRacer { endpoint, _ in
            if endpoint.kind == .lan { throw URLError(.cannotConnectToHost) }
            if endpoint.kind == .tunnel {
                return RouteProbeOutcome(endpoint: endpoint, latencyMs: 36, authenticated: true)
            }
            try await Task.sleep(nanoseconds: 250_000_000)
            return RouteProbeOutcome(endpoint: endpoint, latencyMs: 250, authenticated: true)
        }
        let outdoorWinner = try await outdoorRacer.selectBestRoute(candidates: original.routes, sessionToken: "s1")
        check(outdoorWinner.endpoint.kind == .tunnel, "5G selects public HTTPS tunnel without VPN")

        // 4. RouteRacer: Home Wi-Fi (LAN wins with 2ms latency)
        let homeRacer = RouteRacer { endpoint, _ in
            RouteProbeOutcome(endpoint: endpoint, latencyMs: endpoint.kind == .lan ? 2 : 45, authenticated: true)
        }
        let homeWinner = try await homeRacer.selectBestRoute(candidates: original.routes, sessionToken: "s1")
        check(homeWinner.endpoint.kind == .lan, "Home Wi-Fi prefers LAN")

        // 5. SSE incremental frame parser
        var parser = SSEFrameParser()
        let raw = """
        event: rooms_updated
        data: {"at":"2026-11-22T05:00:00Z","rooms":[{"id":"r1","title":"bot优化","busy":true}]}

        event: approvals_updated
        data: {"count":1,"approvals":[{"id":"rvw_1","kind":"RULE","title":"测试规则","detail":"内容","status":"PENDING"}]}

        """
        let frames = parser.feed(raw + "\n")
        check(frames.count == 2, "SSE frame count == 2")
        if case .roomsUpdated(let rooms) = SSEFrameParser.decodeEvent(name: frames[0].event, data: frames[0].data) {
            check(rooms.first?.title == "bot优化" && rooms.first?.busy == true, "SSE room decoded")
        } else {
            check(false, "Expected .roomsUpdated")
        }

        print("✅ All 5 JasmineMobileCore Swift 6 checks passed!")
    }
}
