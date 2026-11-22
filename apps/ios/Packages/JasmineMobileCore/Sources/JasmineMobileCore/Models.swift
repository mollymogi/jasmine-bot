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

public enum MediaAttachmentKind: String, Codable, Hashable, Sendable {
    case image
    case video
    case audio
    case file

    public static func classify(filePath: String, extHint: String? = nil) -> MediaAttachmentKind {
        let rawExt = (extHint ?? (filePath as NSString).pathExtension)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        switch rawExt {
        case "png", "jpg", "jpeg", "webp", "gif", "heic", "bmp":
            return .image
        case "mp4", "mov", "m4v", "webm", "mkv":
            return .video
        case "mp3", "wav", "m4a", "aac", "flac", "ogg":
            return .audio
        default:
            return .file
        }
    }
}

public struct RoomMediaAttachment: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let ext: String
    public let kind: MediaAttachmentKind

    public init(path: String, name: String? = nil, ext: String? = nil) {
        let cleanedPath = Self.normalizeLocalPath(path)
        self.path = cleanedPath
        let inferredName = (cleanedPath as NSString).lastPathComponent
        self.name = (name?.isEmpty == false ? name! : inferredName)
        let inferredExt = ext ?? (cleanedPath as NSString).pathExtension.lowercased()
        self.ext = inferredExt
        self.kind = MediaAttachmentKind.classify(filePath: cleanedPath, extHint: inferredExt)
    }

    public static func normalizeLocalPath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("file://") {
            if let url = URL(string: s), url.isFileURL {
                return url.path
            }
            s = String(s.dropFirst("file://".count))
            return s.removingPercentEncoding ?? s
        }
        return s.removingPercentEncoding ?? s
    }
}

public enum MarkdownBlock: Equatable, Identifiable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(language: String?, code: String)
    case blockquote(String)
    case listItem(bullet: String, text: String)
    case table(headers: [String], rows: [[String]])

    public var id: String {
        switch self {
        case .heading(let l, let t): return "h\(l):\(t.prefix(32))"
        case .paragraph(let t): return "p:\(t.prefix(32))"
        case .codeBlock(let lang, let c): return "code:\(lang ?? ""):\(c.prefix(32))"
        case .blockquote(let t): return "q:\(t.prefix(32))"
        case .listItem(let b, let t): return "li:\(b):\(t.prefix(32))"
        case .table(let h, let r): return "tbl:\(h.joined()):\(r.count)"
        }
    }
}

public struct ChatMessageItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let role: String?
    public let senderKind: String?
    public let memberId: String?
    public let speaker: String?
    public let status: String?
    public let text: String?
    public let content: String?
    public let error: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let phaseReplies: [PhaseReplyItem]?
    public let referenceFiles: [RoomMediaAttachment]?

    public init(
        id: String,
        role: String? = nil,
        senderKind: String? = nil,
        memberId: String? = nil,
        speaker: String? = nil,
        status: String? = nil,
        text: String? = nil,
        content: String? = nil,
        error: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        phaseReplies: [PhaseReplyItem]? = nil,
        referenceFiles: [RoomMediaAttachment]? = nil
    ) {
        self.id = id
        self.role = role
        self.senderKind = senderKind
        self.memberId = memberId
        self.speaker = speaker
        self.status = status
        self.text = text
        self.content = content
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phaseReplies = phaseReplies
        self.referenceFiles = referenceFiles
    }

    public var displayBody: String {
        let primary = (text ?? content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
        if let latestPhase = phaseReplies?.last?.text, !latestPhase.isEmpty {
            return latestPhase
        }
        return ""
    }

    public var isUser: Bool {
        if senderKind == "user" { return true }
        if senderKind == "agent" { return false }
        return memberId == nil && (role == nil || role == "user")
    }

    public var isWorking: Bool {
        guard let s = status?.lowercased() else { return false }
        return s == "working" || s == "sending" || s == "streaming" || s == "queued"
    }

    /// Extracts all explicit `referenceFiles` plus inline `file:///...` or `/Users/...` `/Volumes/...` media paths.
    public var extractedMediaAttachments: [RoomMediaAttachment] {
        var result: [RoomMediaAttachment] = []
        var seen = Set<String>()
        for item in referenceFiles ?? [] where item.kind == .image || item.kind == .video || item.kind == .audio {
            if seen.insert(item.path).inserted {
                result.append(item)
            }
        }
        let body = displayBody
        guard !body.isEmpty else { return result }

        // 1) Match file:///... links inside Markdown or parentheses
        let fileUrlPattern = #"file://(/[^\s\)\]>\"'`]+)"#
        if let regex = try? NSRegularExpression(pattern: fileUrlPattern) {
            let ns = body as NSString
            for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range)
                let att = RoomMediaAttachment(path: raw)
                if (att.kind == .image || att.kind == .video || att.kind == .audio), seen.insert(att.path).inserted {
                    result.append(att)
                }
            }
        }

        // 2) Match bare absolute media paths (/Users/... or /Volumes/...)
        let absPathPattern = #"(?:/Users/|/Volumes/)[^\s\)\]>\"'`,;，。；]+\.(?:mp4|mov|m4v|webm|png|jpg|jpeg|webp|gif|mp3|wav)"#
        if let regex = try? NSRegularExpression(pattern: absPathPattern, options: [.caseInsensitive]) {
            let ns = body as NSString
            for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range)
                let att = RoomMediaAttachment(path: raw)
                if (att.kind == .image || att.kind == .video || att.kind == .audio), seen.insert(att.path).inserted {
                    result.append(att)
                }
            }
        }
        return result
    }

    /// Replaces verbose `[label](file:///long/path/foo.mp4)` links with concise readable badges so bubbles stay tidy.
    public var cleanedMarkdownBody: String {
        var text = displayBody
        guard !text.isEmpty else { return "" }

        // Replace Markdown `[label](file:///...)` or `[label](</abs/path>)`
        let mdFileLinkPattern = #"\[([^\]]+)\]\(\s*<?(?:file://)?(/[^>\)\s]+)>?\s*\)"#
        if let regex = try? NSRegularExpression(pattern: mdFileLinkPattern) {
            let ns = text as NSString
            var out = ""
            var lastLoc = 0
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: lastLoc, length: m.range.location - lastLoc))
                let label = ns.substring(with: m.range(at: 1))
                let pathStr = RoomMediaAttachment.normalizeLocalPath(ns.substring(with: m.range(at: 2)))
                let kind = MediaAttachmentKind.classify(filePath: pathStr)
                let icon = kind == .video ? "🎬" : (kind == .image ? "🖼️" : "📄")
                out += "`\(icon) \(label)`"
                lastLoc = m.range.location + m.range.length
            }
            out += ns.substring(from: lastLoc)
            text = out
        }

        // Replace bare `(file:///...)` or `file:///...`
        let bareFileUrlPattern = #"\(?file://(/[^\s\)\]>\"'`]+)\)?"#
        if let regex = try? NSRegularExpression(pattern: bareFileUrlPattern) {
            let ns = text as NSString
            var out = ""
            var lastLoc = 0
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: lastLoc, length: m.range.location - lastLoc))
                let pathStr = RoomMediaAttachment.normalizeLocalPath(ns.substring(with: m.range(at: 1)))
                let baseName = (pathStr as NSString).lastPathComponent
                let kind = MediaAttachmentKind.classify(filePath: pathStr)
                let icon = kind == .video ? "🎬" : (kind == .image ? "🖼️" : "📄")
                out += "`\(icon) \(baseName)`"
                lastLoc = m.range.location + m.range.length
            }
            out += ns.substring(from: lastLoc)
            text = out
        }

        return text
    }

    public static func parseMarkdownBlocks(_ raw: String) -> [MarkdownBlock] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var idx = 0
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            let joined = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block ```
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                idx += 1
                while idx < lines.count {
                    if lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        idx += 1
                        break
                    }
                    codeLines.append(lines[idx])
                    idx += 1
                }
                blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            // Markdown table
            if trimmed.hasPrefix("|"), idx + 1 < lines.count {
                let nextTrimmed = lines[idx + 1].trimmingCharacters(in: .whitespaces)
                if nextTrimmed.hasPrefix("|") && nextTrimmed.contains("---") {
                    flushParagraph()
                    let parseRow: (String) -> [String] = { row in
                        var s = row.trimmingCharacters(in: .whitespaces)
                        if s.hasPrefix("|") { s.removeFirst() }
                        if s.hasSuffix("|") { s.removeLast() }
                        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    }
                    let headers = parseRow(trimmed)
                    var rows: [[String]] = []
                    idx += 2
                    while idx < lines.count {
                        let rline = lines[idx].trimmingCharacters(in: .whitespaces)
                        guard rline.hasPrefix("|") else { break }
                        rows.append(parseRow(rline))
                        idx += 1
                    }
                    blocks.append(.table(headers: headers, rows: rows))
                    continue
                }
            }

            if trimmed.isEmpty {
                flushParagraph()
                idx += 1
                continue
            }

            // ATX Heading # .. ####
            if let headingMatch = trimmed.range(of: #"^(#{1,4})\s+(.+)$"#, options: .regularExpression) {
                let full = String(trimmed[headingMatch])
                let hashes = full.prefix { $0 == "#" }
                let title = full.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
                flushParagraph()
                blocks.append(.heading(level: hashes.count, text: title))
                idx += 1
                continue
            }

            // Horizontal rule ---
            if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                idx += 1
                continue
            }

            // Blockquote >
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while idx < lines.count {
                    let ql = lines[idx].trimmingCharacters(in: .whitespaces)
                    guard ql.hasPrefix(">") else { break }
                    var content = String(ql.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoteLines.append(content)
                    idx += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Bullet or numbered list item
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                blocks.append(.listItem(bullet: "•", text: String(trimmed.dropFirst(2))))
                idx += 1
                continue
            }
            if let numRange = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushParagraph()
                let prefix = String(trimmed[numRange]).trimmingCharacters(in: .whitespaces)
                let rest = String(trimmed[numRange.upperBound...])
                blocks.append(.listItem(bullet: prefix, text: rest))
                idx += 1
                continue
            }

            paragraphBuffer.append(line)
            idx += 1
        }
        flushParagraph()
        return blocks
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
        let senderKind = try? c.decode(String.self, forKey: DynamicKey("senderKind"))
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

        struct RawRefFile: Decodable {
            let path: String?
            let name: String?
            let ext: String?
        }
        let rawRefs = (try? c.decode([RawRefFile].self, forKey: DynamicKey("referenceFiles"))) ?? []
        let parsedRefs = rawRefs.compactMap { rf -> RoomMediaAttachment? in
            guard let p = rf.path, !p.isEmpty else { return nil }
            return RoomMediaAttachment(path: p, name: rf.name, ext: rf.ext)
        }

        self.item = ChatMessageItem(
            id: id,
            role: role,
            senderKind: senderKind,
            memberId: memberId,
            speaker: speaker,
            status: status,
            text: text,
            content: content,
            error: error,
            createdAt: createdAt,
            updatedAt: updatedAt,
            phaseReplies: phases,
            referenceFiles: parsedRefs.isEmpty ? nil : parsedRefs
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
