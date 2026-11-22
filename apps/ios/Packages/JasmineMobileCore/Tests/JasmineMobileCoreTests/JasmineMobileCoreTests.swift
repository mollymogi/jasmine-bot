import Foundation
#if canImport(XCTest)
import XCTest
@testable import JasmineMobileCore

final class JasmineMobileCoreTests: XCTestCase {
    func testDeepLinkQRRoundTrip() throws {
        let original = MobilePairingBundle(
            version: 1,
            hostName: "mercuryliumac-mini.local",
            pairingToken: "tok_secret_123456",
            routes: [
                RouteEndpoint(kind: .lan, origin: "http://192.168.3.159:4319"),
                RouteEndpoint(kind: .tunnel, origin: "https://bot.example.com")
            ]
        )
        let b64 = try JSONEncoder().encode(original).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let parsed = try MobilePairingBundle.parse(qrString: "jasminebot://pair?data=\(b64)")
        XCTAssertEqual(parsed.routes.count, 2)
        XCTAssertEqual(parsed.routes[1].kind, .tunnel)
    }

    func testRouteRacerFailover() async throws {
        let racer = RouteRacer { endpoint, _ in
            if endpoint.kind == .lan { throw URLError(.cannotConnectToHost) }
            return RouteProbeOutcome(endpoint: endpoint, latencyMs: 35, authenticated: true)
        }
        let winner = try await racer.selectBestRoute(
            candidates: [
                RouteEndpoint(kind: .lan, origin: "http://192.168.3.159:4319"),
                RouteEndpoint(kind: .tunnel, origin: "https://bot.example.com")
            ],
            sessionToken: "tok"
        )
        XCTAssertEqual(winner.endpoint.kind, .tunnel)
    }
}
#endif
