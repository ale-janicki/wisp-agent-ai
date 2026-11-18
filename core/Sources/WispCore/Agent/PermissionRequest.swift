import Foundation

/// One `can_use_tool` control request: a tool call the CLI holds until the host answers.
public struct PermissionRequest: Identifiable, Equatable, Sendable {
    public let id: String
    public let toolName: String
    public let toolUseId: String?
    /// "rodar mkdir x", "editar ~/notes.txt": what follows "O Claude quer".
    public let summary: String
    /// The whole input, never cut: what the user reads before allowing.
    public let detail: String
    /// The summary was cut to fit one line.
    public let summaryTruncated: Bool
    /// The summary can hide part of what runs (cut, several lines, or chained commands): the card holds
    /// Permitir and Sempre permitir until the full input was opened.
    public let requiresExpansion: Bool
    /// The tool input as the CLI sent it, echoed back as `updatedInput` on allow.
    public let inputJSON: String
    /// The `addRules` suggestions that write a settings file, as a JSON array; nil when the CLI offered none.
    public let persistJSON: String?
    /// The rules "Sempre permitir" adds, e.g. `Bash(touch x *)`.
    public let persistRules: [String]

    public var canPersist: Bool { persistJSON != nil }

    static let summaryLimit = 120

    public init(
        id: String, toolName: String, toolUseId: String? = nil, summary: String, detail: String,
        summaryTruncated: Bool = false, requiresExpansion: Bool = false,
        inputJSON: String = "{}", persistJSON: String? = nil, persistRules: [String] = []
    ) {
        self.id = id
        self.toolName = toolName
        self.toolUseId = toolUseId
        self.summary = summary
        self.detail = detail
        self.summaryTruncated = summaryTruncated
        self.requiresExpansion = requiresExpansion
        self.inputJSON = inputJSON
        self.persistJSON = persistJSON
        self.persistRules = persistRules
    }

    /// The `request` object of a `control_request` line; nil when it is not a `can_use_tool` with an id.
    public init?(requestId: String, request: [String: Any], home: String = NSHomeDirectory()) {
        guard request["subtype"] as? String == "can_use_tool", !requestId.isEmpty else { return nil }
        let tool = request["tool_name"] as? String ?? ""
        let input = request["input"] as? [String: Any] ?? [:]
        let persist = (request["permission_suggestions"] as? [[String: Any]] ?? []).filter(Self.persists)
        let rules = persist.flatMap { ($0["rules"] as? [[String: Any]] ?? []).map(Self.ruleText) }
        let phrase = Self.phrase(tool: tool, input: input, home: home)
        let truncated = phrase.count > Self.summaryLimit
        self.init(
            id: requestId,
            toolName: tool,
            toolUseId: request["tool_use_id"] as? String,
            summary: Self.summary(phrase),
            detail: Self.detail(tool: tool, input: input, description: request["description"] as? String),
            summaryTruncated: truncated,
            requiresExpansion: Self.requiresExpansion(tool: tool, input: input, summaryTruncated: truncated),
            inputJSON: Self.json(input, pretty: false) ?? "{}",
            persistJSON: persist.isEmpty ? nil : Self.json(persist, pretty: false),
            persistRules: rules
        )
    }

    /// Only rules saved to a settings file count as "always"; `setMode` and anything scoped to the session do not.
    private static func persists(_ suggestion: [String: Any]) -> Bool {
        suggestion["type"] as? String == "addRules" && suggestion["behavior"] as? String == "allow"
            && suggestion["destination"] as? String != "session"
    }

    private static func ruleText(_ rule: [String: Any]) -> String {
        let tool = rule["toolName"] as? String ?? ""
        guard let content = rule["ruleContent"] as? String, !content.isEmpty else { return tool }
        return "\(tool)(\(content))"
    }

    static func summary(tool: String, input: [String: Any], home: String) -> String {
        summary(phrase(tool: tool, input: input, home: home))
    }

    private static func summary(_ phrase: String) -> String {
        guard phrase.count > summaryLimit else { return phrase }
        return String(phrase.prefix(summaryLimit - 1)) + "…"
    }

    /// The summary flattens whitespace, so a second line reads as an argument; a separator chains another
    /// command the summary may cut. Either way the user has to see the full command.
    static func requiresExpansion(tool: String, input: [String: Any], summaryTruncated: Bool) -> Bool {
        if summaryTruncated { return true }
        guard tool == "Bash" || tool == "PowerShell", let command = input["command"] as? String else { return false }
        return command.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline)
            || chainsCommands(command)
    }

    /// `;`, `&&`, `||`, `|`, a lone `&`, backticks, `$(`, `<(` or `>(`. Redirections (`2>&1`, `&>`) are not
    /// separators. Quotes are not parsed: a separator inside a string counts too, which only costs a click.
    static func chainsCommands(_ command: String) -> Bool {
        let chars = Array(command)
        for (i, c) in chars.enumerated() {
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let previous: Character? = i > 0 ? chars[i - 1] : nil
            switch c {
            case ";", "|", "`": return true
            case "$", "<", ">": if next == "(" { return true }
            case "&": if previous != ">", previous != "<", next != ">" { return true }
            default: break
            }
        }
        return false
    }

    private static func phrase(tool: String, input: [String: Any], home: String) -> String {
        func string(_ key: String) -> String? {
            (input[key] as? String).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func path(_ key: String) -> String? {
            guard let value = string(key) else { return nil }
            if value == home { return "~" }
            return value.hasPrefix(home + "/") ? "~" + value.dropFirst(home.count) : value
        }
        let phrase: String = switch tool {
        case "Bash", "PowerShell": string("command").map { "rodar \($0)" } ?? "rodar um comando"
        case "Edit", "MultiEdit": path("file_path").map { "editar \($0)" } ?? "editar um arquivo"
        case "Write": path("file_path").map { "escrever \($0)" } ?? "escrever um arquivo"
        case "NotebookEdit": path("notebook_path").map { "editar \($0)" } ?? "editar um notebook"
        case "Read": path("file_path").map { "ler \($0)" } ?? "ler um arquivo"
        case "Glob", "Grep": string("pattern").map { "buscar \($0)" } ?? "buscar arquivos"
        case "WebFetch": string("url").map { "abrir \($0)" } ?? "abrir uma página"
        case "WebSearch": string("query").map { "pesquisar \($0)" } ?? "pesquisar na web"
        default: firstString(input).map { "usar \(tool): \($0)" } ?? "usar \(tool)"
        }
        return phrase
    }

    private static func firstString(_ input: [String: Any]) -> String? {
        input.keys.sorted().lazy.compactMap { input[$0] as? String }
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty }
    }

    static func detail(tool: String, input: [String: Any], description: String?) -> String {
        var parts: [String] = []
        if let description, !description.isEmpty { parts.append(description) }
        if tool == "Bash" || tool == "PowerShell", let command = input["command"] as? String {
            parts.append(command)
        } else if let body = json(input, pretty: true) {
            parts.append(body)
        }
        return parts.joined(separator: "\n\n")
    }

    static func json(_ value: Any, pretty: Bool) -> String? {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum PermissionDecision: Equatable, Sendable {
    case allow
    case allowAlways
    case deny

    public var allows: Bool { self != .deny }
}

/// The host's half of the CLI control protocol over stream-json stdin.
public enum ClaudeControl {
    /// Claude reads this as the tool result and carries on without the tool.
    public static let denyMessage = "O usuário negou esta ação no Wisp. Não tente de novo do mesmo jeito; siga sem ela ou pergunte o que fazer."

    /// One `control_response` line, newline included.
    public static func response(to request: PermissionRequest, _ decision: PermissionDecision) -> Data {
        var answer: [String: Any]
        switch decision {
        case .deny:
            answer = ["behavior": "deny", "message": denyMessage]
        case .allow, .allowAlways:
            answer = ["behavior": "allow", "updatedInput": object(request.inputJSON) ?? [String: Any]()]
            if decision == .allowAlways, let persist = request.persistJSON.flatMap(object) {
                answer["updatedPermissions"] = persist
            }
        }
        let line: [String: Any] = [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": request.id, "response": answer],
        ]
        var data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    private static func object(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }
}
