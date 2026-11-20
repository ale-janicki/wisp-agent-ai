import Foundation

public struct CodexEventDecoder {
    public private(set) var threadId: String?
    public private(set) var turnStarted = false
    public private(set) var finished = false
    private var lastMessage = ""
    private var failure: String?
    private let model: String
    public static let incomplete = "o Codex terminou sem concluir o turno"
    private static let summaryLimit = 80

    public init(model: String = "") {
        self.model = model
    }

    public mutating func decode(line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String
        else { return [.malformed(line)] }
        let item = object["item"] as? [String: Any] ?? [:]
        switch type {
        case "thread.started":
            guard let id = object["thread_id"] as? String, !id.isEmpty else { return [.ignored(type: type)] }
            threadId = id
            return [.initialized(sessionId: "", model: model, subscription: true), .engineSession(engine: "codex", id: id)]
        case "turn.started":
            turnStarted = true
            return [.thinking]
        case "turn.completed":
            finished = true
            return [.result(sessionId: "", text: lastMessage, isError: false, denials: [])]
        case "turn.failed":
            finished = true
            let message = (object["error"] as? [String: Any])?["message"] as? String
            return [.result(sessionId: "", text: message ?? failure ?? "o Codex falhou", isError: true, denials: [])]
        case "error":
            failure = object["message"] as? String ?? failure
            return [.ignored(type: type)]
        case "item.started":
            return started(item)
        case "item.completed":
            return completed(item)
        default:
            return [.ignored(type: type)]
        }
    }

    public func closing(exitCode: Int32, stderrTail: String, resumed: Bool) -> [ClaudeEvent] {
        guard !finished else { return [] }
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode == 0 {
            return [.result(sessionId: "", text: Self.incomplete, isError: true, denials: [])]
        }
        if resumed, !turnStarted, !Self.looksLikeLogin(tail + (failure ?? "")) {
            return [.result(sessionId: "", text: ConversationTranscript.codexLostSession, isError: true, denials: [])]
        }
        let detail = failure ?? tail
        let hint = Self.looksLikeLogin(detail) ? "\nConserto: rodar `codex login` no Terminal." : ""
        let head = "codex saiu com código \(exitCode)"
        return [.result(sessionId: "", text: detail.isEmpty ? head : "\(head): \(detail)\(hint)", isError: true, denials: [])]
    }

    private static func looksLikeLogin(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["not logged in", "codex login", "401", "unauthorized", "authentication"].contains { lowered.contains($0) }
    }

    private func started(_ item: [String: Any]) -> [ClaudeEvent] {
        let id = item["id"] as? String ?? ""
        switch item["type"] as? String {
        case "command_execution":
            let command = item["command"] as? String ?? ""
            var events: [ClaudeEvent] = [.toolUse(name: "Bash", summary: String(command.prefix(Self.summaryLimit)))]
            let paths = SentFiles.enviarFiles(in: command)
            if !paths.isEmpty, !id.isEmpty { events.append(.fileSend(toolUseId: id, paths: paths)) }
            return events
        case "mcp_tool_call":
            let name = "\(item["server"] as? String ?? "mcp").\(item["tool"] as? String ?? "")"
            return [.toolUse(name: name, summary: "")]
        case "web_search":
            return [.toolUse(name: "WebSearch", summary: String((item["query"] as? String ?? "").prefix(Self.summaryLimit)))]
        default:
            return [.ignored(type: "item.started.\(item["type"] as? String ?? "")")]
        }
    }

    private mutating func completed(_ item: [String: Any]) -> [ClaudeEvent] {
        let id = item["id"] as? String ?? ""
        switch item["type"] as? String {
        case "agent_message":
            let text = item["text"] as? String ?? ""
            guard !text.isEmpty else { return [] }
            lastMessage = text
            return [.text(text)]
        case "reasoning":
            return [.thinking]
        case "command_execution":
            let status = item["status"] as? String ?? ""
            let code = item["exit_code"] as? Int
            let failed = status == "failed" || status == "declined" || (code ?? 0) != 0
            return [.toolResult(toolUseId: id, isError: failed, text: item["aggregated_output"] as? String ?? "")]
        case "mcp_tool_call":
            let failed = item["status"] as? String == "failed"
            let message = (item["error"] as? [String: Any])?["message"] as? String ?? ""
            return [.toolResult(toolUseId: id, isError: failed, text: message)]
        case "file_change":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let path = changes.first?["path"] as? String ?? ""
            return [.toolUse(name: "Edit", summary: String(path.prefix(Self.summaryLimit)))]
        default:
            return [.ignored(type: "item.completed.\(item["type"] as? String ?? "")")]
        }
    }
}
