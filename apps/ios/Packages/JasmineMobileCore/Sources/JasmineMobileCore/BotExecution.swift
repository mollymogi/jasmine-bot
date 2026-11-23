import Foundation

public struct BotModelChoice: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String?
    public let source: String?
}

public struct BotCLIChoice: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String?
    public let installed: Bool?
    public let herdrSupported: Bool?
    public let models: [BotModelChoice]?
}

public struct BotExecutionDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let online: Bool
    public let defaultCwd: String
    public let clis: [BotCLIChoice]

    private struct Catalog: Decodable {
        var device: String?
        var defaultProject: String?
        var clis: [BotCLIChoice]
    }

    private struct Node: Decodable {
        var id: String
        var label: String
        var authorized: Bool
        var online: Bool?
        var defaultCwd: String?
        var catalog: Catalog?
    }

    public static func decodeInventories(primary: Data, workers: Data) throws -> [Self] {
        struct Nodes: Decodable { var nodes: [Node] }
        func installed(_ catalog: Catalog?) -> [BotCLIChoice] {
            (catalog?.clis ?? []).filter { $0.installed != false && $0.herdrSupported != false }
        }
        let host = try JSONDecoder().decode(Catalog.self, from: primary)
        let nodes = try JSONDecoder().decode(Nodes.self, from: workers)
        return [Self(id: "local", label: host.device ?? "数据主机", online: true,
                     defaultCwd: host.defaultProject ?? "", clis: installed(host))]
            + nodes.nodes.filter(\.authorized).map {
                Self(id: $0.id, label: $0.label, online: $0.online == true,
                     defaultCwd: $0.defaultCwd ?? "", clis: installed($0.catalog))
            }
    }
}

public struct BotCreationRequest: Sendable {
    public let id: String
    public let name: String
    public let device: BotExecutionDevice
    public let cli: String
    public let model: String
    public let source: String
    public let cwd: String

    public init(id: UUID, name: String, device: BotExecutionDevice, cli: String,
                model: String, source: String, cwd: String) {
        self.id = id.uuidString.lowercased()
        self.name = name
        self.device = device
        self.cli = cli
        self.model = model
        self.source = source
        self.cwd = cwd
    }

    var payload: [String: Any] {
        let member: [String: String] = [
            "id": "bot", "name": name, "role": "lead", "cli": cli,
            "requestedModel": model, "modelSource": source, "executionNodeId": device.id,
            "executionNodeLabel": device.label, "executionCwd": cwd
        ]
        return ["id": id, "kind": "direct", "title": name, "members": [member]]
    }

    func matches(_ room: ChatRoomSummary) -> Bool {
        guard room.id == id, room.kind == "direct", room.title == name,
              let bot = room.members?.first else { return false }
        return bot.cli == cli && bot.requestedModel == model &&
            (bot.executionNodeId ?? "local") == device.id && bot.executionCwd == cwd
    }
}
