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

        // 6. Media extraction & Markdown table/code/file-link cleaning (Chinese path regression check)
        let msg = ChatMessageItem(
            id: "m1",
            senderKind: "agent",
            memberId: "agy-1",
            speaker: "视频操作",
            text: """
            ### 粗剪产出
            请查看 [ENTRANCE_5SHOTS_v3_白天营业版_粗剪.mp4](file:///Volumes/Spare/videoMake/Zeus_Bin_第二罐热牛奶_20261113/ENTRANCE_5SHOTS_v3_白天营业版_粗剪.mp4)，确认白天光感。

            | 镜头 | 状态 |
            |---|---|
            | s01 | **通过** |
            """
        )
        let extracted = msg.extractedMediaAttachments
        check(extracted.count == 1 && extracted[0].kind == .video, "Extracted Chinese MP4 video attachment")
        check(extracted[0].path == "/Volumes/Spare/videoMake/Zeus_Bin_第二罐热牛奶_20261113/ENTRANCE_5SHOTS_v3_白天营业版_粗剪.mp4", "Decoded local video path: \(extracted[0].path)")
        check(!msg.cleanedMarkdownBody.contains("file:///Volumes/Spare"), "Cleaned verbose file:// URL from bubble text")
        let blocks = ChatMessageItem.parseMarkdownBlocks(msg.cleanedMarkdownBody)
        check(blocks.contains { if case .table(let h, _) = $0 { return h == ["镜头", "状态"] }; return false }, "Parsed Markdown table block")

        let executionDevices = try BotExecutionDevice.decodeInventories(
            primary: Data(#"{"device":"storage","clis":[{"id":"codex"}]}"#.utf8),
            workers: Data(#"{"nodes":[{"id":"linux","label":"Linux","authorized":true,"defaultCwd":"/work","catalog":{"clis":[{"id":"claude","installed":true}]}},{"id":"pending","label":"Pending","authorized":false}]}"#.utf8)
        )
        check(executionDevices.map(\.id) == ["local", "linux"], "Authorized devices are selectable")
        check(executionDevices.last?.clis.map(\.id) == ["claude"], "CLI inventory is device-specific")
        check(executionDevices.last?.defaultCwd == "/work", "Execution directory belongs to the worker")

        print("✅ All 7 JasmineMobileCore checks passed!")
    }
}
