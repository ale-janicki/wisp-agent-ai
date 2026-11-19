import Foundation

public struct TranscriptParser: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var messages: [ConversationMessage]
        public var prompts: Int
        public var turnOpen: Bool
        public var status: String?
    }

    private static let wrapperPrefixes = ["<command-", "<local-command", "<system-reminder", "<task-notification", "<bash-"]
    private static let syntheticPrompts = ["[Request interrupted by user"]
    private static let syntheticModel = "<synthetic>"
    private static let botRulePrefix = "[regra do topico]"
    private static let botContextPrefix = "[contexto do bot]"
    private static let botMessageMarker = "Mensagem do Ale:\n"
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public let statusPrefix: String?
    public let telegramHTML: Bool

    private var partial = Data()
    private var messages: [ConversationMessage] = []
    private var pendingReply: [String] = []
    private var pendingId = UUID()
    private var sendCalls: [String: [String]] = [:]
    private var pendingSent: [String] = []
    private var pendingLinks: [String] = []
    private var skippingTurn = false
    private var prompts = 0
    private var turnOpen = false
    private var status: String?

    public init(statusPrefix: String?, telegramHTML: Bool = false) {
        self.statusPrefix = statusPrefix
        self.telegramHTML = telegramHTML
    }

    public var snapshot: Snapshot {
        var all = messages
        if let reply = openReply { all.append(reply) }
        return Snapshot(messages: all, prompts: prompts, turnOpen: turnOpen, status: status)
    }

    public mutating func consume(_ data: Data) {
        partial.append(data)
        guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = partial[partial.startIndex..<lastNewline]
        for line in complete.split(separator: UInt8(ascii: "\n")) { read(Data(line)) }
        partial = Data(partial[partial.index(after: lastNewline)...])
    }

    public mutating func finish() {
        guard !partial.isEmpty else { return }
        let last = partial
        partial = Data()
        read(last)
    }

    private var joinedReply: String? {
        let text = pendingReply.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private var openReply: ConversationMessage? {
        let files = SentFiles.cards(sent: pendingSent, replyText: pendingLinks.joined(separator: "\n"))
        guard joinedReply != nil || !files.isEmpty else { return nil }
        return ConversationMessage(role: .assistant, text: joinedReply ?? "", id: pendingId, files: files)
    }

    private mutating func flushReply() {
        if let reply = openReply { messages.append(reply) }
        pendingReply = []
        sendCalls = [:]
        pendingSent = []
        pendingLinks = []
        pendingId = UUID()
    }

    private mutating func read(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              object["isMeta"] as? Bool != true,
              object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else { return }

        switch type {
        case "user":
            if let results = message["content"] as? [[String: Any]] {
                for item in results where item["type"] as? String == "tool_result" {
                    guard let id = item["tool_use_id"] as? String, let paths = sendCalls.removeValue(forKey: id),
                          item["is_error"] as? Bool != true else { continue }
                    for path in paths where !pendingSent.contains(path) { pendingSent.append(path) }
                }
                return
            }
            guard let raw = message["content"] as? String else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !Self.wrapperPrefixes.contains(where: trimmed.hasPrefix),
                  !Self.syntheticPrompts.contains(where: trimmed.hasPrefix) else { return }
            if trimmed.hasPrefix(Self.botRulePrefix) {
                skippingTurn = true
                return
            }
            skippingTurn = false
            flushReply()
            let time = (object["timestamp"] as? String).flatMap { try? Date($0, strategy: Self.timestampStyle) }
            messages.append(ConversationMessage(role: .user, text: Self.unwrapBotContext(trimmed), time: time))
            prompts += 1
            turnOpen = true
        case "assistant":
            guard !skippingTurn, message["model"] as? String != Self.syntheticModel,
                  let items = message["content"] as? [[String: Any]] else { return }
            for item in items where item["type"] as? String == "tool_use" {
                guard item["name"] as? String == "Bash", let id = item["id"] as? String,
                      let command = (item["input"] as? [String: Any])?["command"] as? String else { continue }
                let paths = SentFiles.enviarFiles(in: command)
                if !paths.isEmpty { sendCalls[id] = paths }
            }
            for item in items where item["type"] as? String == "text" {
                guard let text = item["text"] as? String else { continue }
                let parts = ReplyFormatter.split(text, statusPrefix: statusPrefix)
                pendingLinks.append(parts.body)
                let body = (telegramHTML ? TelegramHTML.markdown(parts.body) : parts.body)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { pendingReply.append(body) }
                if parts.status != nil { status = parts.status }
            }
            if let stop = message["stop_reason"] as? String, stop != "tool_use" { turnOpen = false }
        default:
            return
        }
    }

    private static func unwrapBotContext(_ prompt: String) -> String {
        guard prompt.hasPrefix(botContextPrefix), let marker = prompt.range(of: botMessageMarker, options: .backwards) else {
            return prompt
        }
        let message = prompt[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? prompt : message
    }
}

public enum TranscriptReader {
    public static var defaultProjectsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public static func messages(fromJSONL data: Data, statusPrefix: String?, telegramHTML: Bool = false) -> [ConversationMessage] {
        var parser = TranscriptParser(statusPrefix: statusPrefix, telegramHTML: telegramHTML)
        parser.consume(data)
        parser.finish()
        return parser.snapshot.messages
    }

    public static func projectDirectoryName(forCwd cwd: String) -> String {
        var path = cwd
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let scalars = path.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: Character(scalar)
            default: "-"
            }
        }
        return String(scalars)
    }

    public static func locate(sessionId: String, cwd: String, projectsRoot: URL = defaultProjectsRoot) -> URL? {
        guard !sessionId.isEmpty, !sessionId.contains("/"), !sessionId.hasPrefix(".") else { return nil }
        let fm = FileManager.default
        let fileName = sessionId + ".jsonl"
        let expected = projectsRoot
            .appendingPathComponent(projectDirectoryName(forCwd: cwd), isDirectory: true)
            .appendingPathComponent(fileName)
        if fm.fileExists(atPath: expected.path) { return expected }
        let folders = (try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        return folders
            .map { $0.appendingPathComponent(fileName) }
            .first { fm.fileExists(atPath: $0.path) }
    }

    public static func load(
        sessionId: String,
        cwd: String,
        statusPrefix: String?,
        telegramHTML: Bool = false,
        projectsRoot: URL = defaultProjectsRoot
    ) -> [ConversationMessage]? {
        guard let url = locate(sessionId: sessionId, cwd: cwd, projectsRoot: projectsRoot),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return messages(fromJSONL: data, statusPrefix: statusPrefix, telegramHTML: telegramHTML)
    }
}
