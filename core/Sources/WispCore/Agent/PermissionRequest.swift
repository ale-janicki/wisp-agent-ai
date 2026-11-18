import Foundation

public struct PermissionRequest: Identifiable, Equatable, Sendable {
    public let id: String
    public let toolName: String
    public let toolUseId: String?
    public let summary: String
    public let detail: String
    public let inputJSON: String
    public let persistJSON: String?
    public let persistRules: [String]

    public var canPersist: Bool { persistJSON != nil }

    private static let summaryLimit = 120
    private static let detailLimit = 4000

    public init(
        id: String, toolName: String, toolUseId: String? = nil, summary: String, detail: String,
        inputJSON: String = "{}", persistJSON: String? = nil, persistRules: [String] = []
    ) {
        self.id = id
        self.toolName = toolName
        self.toolUseId = toolUseId
        self.summary = summary
        self.detail = detail
        self.inputJSON = inputJSON
        self.persistJSON = persistJSON
        self.persistRules = persistRules
    }

    public init?(requestId: String, request: [String: Any], home: String = NSHomeDirectory()) {
        guard request["subtype"] as? String == "can_use_tool", !requestId.isEmpty else { return nil }
        let tool = request["tool_name"] as? String ?? ""
        let input = request["input"] as? [String: Any] ?? [:]
        let persist = (request["permission_suggestions"] as? [[String: Any]] ?? []).filter(Self.persists)
        let rules = persist.flatMap { ($0["rules"] as? [[String: Any]] ?? []).map(Self.ruleText) }
        self.init(
            id: requestId,
            toolName: tool,
            toolUseId: request["tool_use_id"] as? String,
            summary: Self.summary(tool: tool, input: input, home: home),
            detail: Self.detail(tool: tool, input: input, description: request["description"] as? String),
            inputJSON: Self.json(input, pretty: false) ?? "{}",
            persistJSON: persist.isEmpty ? nil : Self.json(persist, pretty: false),
            persistRules: rules
        )
    }

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
        guard phrase.count > summaryLimit else { return phrase }
        return String(phrase.prefix(summaryLimit - 1)) + "…"
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
        let text = parts.joined(separator: "\n\n")
        guard text.count > detailLimit else { return text }
        return String(text.prefix(detailLimit - 1)) + "…"
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

public enum ClaudeControl {
    public static let denyMessage = "O usuário negou esta ação no Wisp. Não tente de novo do mesmo jeito; siga sem ela ou pergunte o que fazer."

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
