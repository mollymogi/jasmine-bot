import Foundation

// MARK: - Multi-Route & Pairing Models

public enum RouteKind: String, Codable, Sendable, CaseIterable {
    case lan
    case tunnel
    case tailscale
    case magicdns
    case custom

    public var displayTitle: String {
        switch self {
        case .lan: return "局域网 Wi-Fi 直连"
        case .tunnel: return "公网 HTTPS 隧道 (免 VPN)"
        case .tailscale: return "Tailscale 内网"
        case .magicdns: return "Tailscale MagicDNS"
        case .custom: return "自定义地址"
        }
    }

    /// Lower priority number means higher preference when racing routes:
    /// Home LAN is fastest (~2ms), Public HTTPS Tunnel works everywhere on 5G without VPN, Tailscale is backup.
    public var priorityRank: Int {
        switch self {
        case .lan: return 0
        case .tunnel: return 1
        case .tailscale: return 2
        case .magicdns: return 3
        case .custom: return 1
        }
    }
}

public struct RouteEndpoint: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(kind.rawValue):\(origin)" }
    public let kind: RouteKind
    public let label: String
    public let origin: String

    public init(kind: RouteKind, label: String? = nil, origin: String) {
        self.kind = kind
        let cleaned = Self.normalizeOrigin(origin)
        self.origin = cleaned
        self.label = label ?? kind.displayTitle
    }

    public static func normalizeOrigin(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            let isPrivate = text.hasPrefix("192.168.") || text.hasPrefix("10.") || text.hasPrefix("100.") || text.hasPrefix("127.") || text.hasPrefix("localhost")
            text = (isPrivate ? "http://" : "https://") + text
        }
        guard var comps = URLComponents(string: text), let scheme = comps.scheme, let host = comps.host else {
            return text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        let portPart = comps.port.map { ":\($0)" } ?? ""
        let bracketHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme.lowercased())://\(bracketHost)\(portPart)"
    }
}

public struct MobilePairingBundle: Codable, Equatable, Sendable {
    public let version: Int
    public let hostName: String
    public let pairingToken: String
    public let routes: [RouteEndpoint]

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case hostName = "host"
        case pairingToken = "token"
        case routes
    }

    public init(version: Int = 1, hostName: String, pairingToken: String, routes: [RouteEndpoint]) {
        self.version = version
        self.hostName = hostName
        self.pairingToken = pairingToken
        self.routes = routes
    }

    /// Parses either:
    /// 1) `jasminebot://pair?data=<base64url>`
    /// 2) `http(s)://<host>:<port>/?pair=<token>&routes=<base64url>#chatrooms`
    /// 3) Legacy `http(s)://<host>:<port>/?pair=<token>#chatrooms`
    public static func parse(qrString: String) throws -> MobilePairingBundle {
        let trimmed = qrString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed) else {
            throw JasmineClientError.invalidPairingCode("无法解析二维码内容")
        }
        let queryItems = comps.queryItems ?? []
        if comps.scheme?.lowercased() == "jasminebot",
           let dataParam = queryItems.first(where: { $0.name == "data" })?.value,
           let decodedData = Self.decodeBase64URL(dataParam) {
            let bundle = try JSONDecoder().decode(MobilePairingBundle.self, from: decodedData)
            guard !bundle.pairingToken.isEmpty, !bundle.routes.isEmpty else {
                throw JasmineClientError.invalidPairingCode("二维码缺少配对令牌或路由地址")
            }
            return bundle
        }

        if let pairToken = queryItems.first(where: { $0.name == "pair" })?.value, !pairToken.isEmpty {
            if let routesParam = queryItems.first(where: { $0.name == "routes" })?.value,
               let decodedData = Self.decodeBase64URL(routesParam),
               let bundle = try? JSONDecoder().decode(MobilePairingBundle.self, from: decodedData),
               !bundle.routes.isEmpty {
                return bundle
            }
            guard let scheme = comps.scheme, let host = comps.host else {
                throw JasmineClientError.invalidPairingCode("缺少服务器主机地址")
            }
            let portPart = comps.port.map { ":\($0)" } ?? ""
            let origin = "\(scheme)://\(host)\(portPart)"
            let inferredKind: RouteKind = scheme.lowercased() == "https" ? .tunnel : (host.hasPrefix("100.") ? .tailscale : .lan)
            return MobilePairingBundle(
                hostName: host,
                pairingToken: pairToken,
                routes: [RouteEndpoint(kind: inferredKind, origin: origin)]
            )
        }
        throw JasmineClientError.invalidPairingCode("不是有效的 Jasmine Bot 配对二维码")
    }

    public static func decodeBase64URL(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

public struct StoredCredentials: Codable, Equatable, Sendable {
    public var hostLabel: String
    public var sessionToken: String
    public var deviceId: String?
    public var routes: [RouteEndpoint]
    public var preferredOrigin: String?

    public init(
        hostLabel: String,
        sessionToken: String,
        deviceId: String? = nil,
        routes: [RouteEndpoint],
        preferredOrigin: String? = nil
    ) {
        self.hostLabel = hostLabel
        self.sessionToken = sessionToken
        self.deviceId = deviceId
        self.routes = routes
        self.preferredOrigin = preferredOrigin
    }
}

// MARK: - Agent Brand & Chat Models (Grok-Bot Inspired)

public enum AgentBrand: String, Codable, Sendable {
    case claude
    case openai
    case grok
    case gemini
    case deepseek
    case glm
    case generic

    public static func resolve(cli: String?, model: String?) -> AgentBrand {
        let m = (model ?? "").lowercased()
        let c = (cli ?? "").lowercased()
        if m.contains("claude") || m.contains("opus") || m.contains("sonnet") || c == "claude" { return .claude }
        if m.contains("grok") || c == "grok" { return .grok }
        if m.contains("gemini") || m.contains("carbon") || m.contains("hydrogen") || c == "agy" { return .gemini }
        if m.contains("deepseek") || c == "dsh" { return .deepseek }
        if m.contains("glm") || m.contains("zhipu") { return .glm }
        if m.contains("gpt") || m.contains("codex") || c == "codex" { return .openai }
        return .generic
    }

    public var shortBadge: String {
        switch self {
        case .claude: return "C"
        case .openai: return "O"
        case .grok: return "G"
        case .gemini: return "✦"
        case .deepseek: return "D"
        case .glm: return "Z"
        case .generic: return "B"
        }
    }
}

public struct RoomMemberItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let role: String?
    public let cli: String?
    public let requestedModel: String?
    public let workerNodeId: String?

    public var brand: AgentBrand {
        AgentBrand.resolve(cli: cli, model: requestedModel)
    }
}

public struct PhaseReplyItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(at ?? "")-\(text.prefix(24))" }
    public let text: String
    public let at: String?
}

public struct ChatMessageItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let role: String?
    public let memberId: String?
    public let speaker: String?
    public let status: String?
    public let text: String?
    public let content: String?
    public let error: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let phaseReplies: [PhaseReplyItem]?

    public var displayBody: String {
        let primary = (text ?? content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
        if let latestPhase = phaseReplies?.last?.text, !latestPhase.isEmpty {
            return latestPhase
        }
        return ""
    }

    public var isUser: Bool {
        memberId == nil && (role == nil || role == "user")
    }

    public var isWorking: Bool {
        guard let s = status?.lowercased() else { return false }
        return s == "working" || s == "sending" || s == "streaming" || s == "queued"
    }
}

public struct ChatRoomSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: String?
    public let title: String
    public let description: String?
    public let project: String?
    public let busy: Bool?
    public let archived: Bool?
    public let autoHandoff: Bool?
    public let maxHandoffHops: Int?
    public let memberCount: Int?
    public let members: [RoomMemberItem]?
    public let updatedAt: String?

    public var isDirectBot: Bool {
        kind == "direct" || (members?.count == 1 && kind != "group")
    }
}

public struct ChatRoomDetail: Codable, Sendable {
    public let id: String
    public let kind: String?
    public let title: String
    public let description: String?
    public let project: String?
    public let autoHandoff: Bool?
    public let maxHandoffHops: Int?
    public let members: [RoomMemberItem]
    public let messages: [ChatRoomMessageEnvelope]

    public var normalizedMessages: [ChatMessageItem] {
        messages.map(\.item)
    }
}

/// Tolerant decoder wrapper so minor Studio message schema variations never fail decoding on iOS.
public struct ChatRoomMessageEnvelope: Codable, Sendable {
    public let item: ChatMessageItem

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        let id = (try? c.decode(String.self, forKey: DynamicKey("id"))) ?? UUID().uuidString
        let role = try? c.decode(String.self, forKey: DynamicKey("role"))
        let memberId = try? c.decode(String.self, forKey: DynamicKey("memberId"))
        let speaker = (try? c.decode(String.self, forKey: DynamicKey("speaker")))
            ?? (try? c.decode(String.self, forKey: DynamicKey("memberName")))
        let status = try? c.decode(String.self, forKey: DynamicKey("status"))
        let text = try? c.decode(String.self, forKey: DynamicKey("text"))
        let content = try? c.decode(String.self, forKey: DynamicKey("content"))
        let error = try? c.decode(String.self, forKey: DynamicKey("error"))
        let createdAt = try? c.decode(String.self, forKey: DynamicKey("createdAt"))
        let updatedAt = try? c.decode(String.self, forKey: DynamicKey("updatedAt"))
        let phases = (try? c.decode([PhaseReplyItem].self, forKey: DynamicKey("phaseReplies")))
            ?? (try? c.decode([PhaseReplyItem].self, forKey: DynamicKey("intermediateReplies")))
        self.item = ChatMessageItem(
            id: id,
            role: role,
            memberId: memberId,
            speaker: speaker,
            status: status,
            text: text,
            content: content,
            error: error,
            createdAt: createdAt,
            updatedAt: updatedAt,
            phaseReplies: phases
        )
    }

    public func encode(to encoder: Encoder) throws {
        try item.encode(to: encoder)
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

// MARK: - Approvals, Quotas & Host Models

public enum ApprovalDecisionMode: String, Codable, Sendable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case reject = "reject"
}

public struct ApprovalItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let title: String
    public let detail: String
    public let projectName: String?
    public let status: String
    public let createdAt: String?
}

public struct QuotaSummaryItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String { provider }
    public let provider: String
    public let label: String
    public let remainingPercent: Double?
    public let resetAt: String?
    public let windowLabel: String?
    public let error: String?
}

public struct WorkerNodeSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let hostname: String?
    public let platform: String?
    public let remoteIp: String?
    public let online: Bool?
    public let authorized: Bool?
    public let defaultCwd: String?
}

public struct HostStatusSummary: Codable, Sendable {
    public let hostname: String
    public let port: Int?
    public let publicTunnelUrl: String?
    public let tunnelActive: Bool?
    public let routes: [RouteEndpoint]?
}

public struct MobileBootstrapResponse: Codable, Sendable {
    public let ok: Bool
    public let serverTime: String?
    public let host: HostStatusSummary
    public let rooms: [ChatRoomSummary]
    public let approvals: [ApprovalItem]
    public let quotas: [QuotaSummaryItem]
    public let workerNodes: [WorkerNodeSummary]
}

public struct RoomTerminalDetails: Codable, Sendable {
    public let terminalSnapshot: String?
    public let activeAgentLabel: String?

    enum CodingKeys: String, CodingKey {
        case terminalSnapshot = "terminalText"
        case activeAgentLabel = "memberLabel"
    }
}

public enum MobileSSEEvent: Sendable {
    case bootstrap(MobileBootstrapResponse)
    case roomsUpdated([ChatRoomSummary])
    case approvalsUpdated([ApprovalItem])
    case ping
}

public enum JasmineClientError: LocalizedError, Sendable, Equatable {
    case invalidPairingCode(String)
    case allRoutesUnreachable([String])
    case unauthorized
    case serverError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidPairingCode(let msg): return msg
        case .allRoutesUnreachable(let tried):
            return "无法连接到主设备（已尝试 \(tried.count) 条通道：\(tried.joined(separator: "、"))）"
        case .unauthorized:
            return "配对会话已失效，请重新扫码或输入 6 位 PIN"
        case .serverError(_, let msg):
            return msg
        }
    }
}
