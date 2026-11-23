import Foundation
#if canImport(XCTest)
import XCTest
@testable import JasmineMobileCore

final class BotExecutionTests: XCTestCase {
    func testExecutionBindingUsesOnlyTheSelectedDevicesCatalogAndDirectory() throws {
        let primary = Data(#"{"device":"host","executionNodeId":"node-host","defaultProject":"/host","clis":[{"id":"claude"}]}"#.utf8)
        let workers = Data("""
        {"nodes":[
          {"id":"node-host","label":"Host","authorized":true,"online":true},
          {"id":"node-one","label":"Linux","defaultCwd":"/work","authorized":true,"online":false,
           "catalog":{"clis":[{"id":"codex","installed":true,"models":[{"id":"model-x","source":"native"}]},
                              {"id":"missing","installed":false}]}},
          {"id":"node-pending","label":"Pending","authorized":false}
        ]}
        """.utf8)
        let devices = try BotExecutionDevice.decodeInventories(primary: primary, workers: workers)
        XCTAssertEqual(devices.map(\.id), ["node-host", "node-one"])
        let linux = devices[1]
        XCTAssertFalse(linux.online)
        XCTAssertEqual(linux.clis.map(\.id), ["codex"])
        let request = BotCreationRequest(id: UUID(), name: "Research", device: linux, cli: "codex",
                                         model: "model-x", source: "native", cwd: linux.defaultCwd)
        XCTAssertNil(request.payload["project"])
        let members = try XCTUnwrap(request.payload["members"] as? [[String: String]])
        XCTAssertEqual(members.first?["executionNodeId"], "node-one")
        XCTAssertEqual(members.first?["executionCwd"], "/work")
        XCTAssertEqual(members.first?["cli"], "codex")
    }
}
#endif
