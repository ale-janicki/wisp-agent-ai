import Foundation

public enum ClaudeStreamDecoder {
    private static let summaryLimit = 80

    public static func decode(line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String
        else { return [.malformed(line)] }

        switch type {
        case "system":
            guard object["subtype"] as? String == "init" else { return [.ignored(type: type)] }
            var events: [ClaudeEvent] = [.initialized(
                sessionId: object["session_id"] as? String ?? "",
                model: object["model"] as? String ?? "",
                subscription: object["apiKeySource"] as? String == "none"
            )]
            if let mode = object["permissionMode"] as? String, !mode.isEmpty { events.append(.permissionMode(mode)) }
            return events
        case "assistant":
            let message = object["message"] as? [String: Any]
            let items = message?["content"] as? [[String: Any]] ?? []
            return items.flatMap(decodeContentItem)
        case "user":
            if object["isReplay"] as? Bool == true { return [.userReplayed] }
            let message = object["message"] as? [String: Any]
            let items = message?["content"] as? [[String: Any]] ?? []
            let results: [ClaudeEvent] = items.compactMap { item in
                guard item["type"] as? String == "tool_result" else { return nil }
                return .toolResult(
                    toolUseId: item["tool_use_id"] as? String ?? "",
                    isError: item["is_error"] as? Bool ?? false,
                    text: resultText(item["content"])
                )
            }
            return results.isEmpty ? [.ignored(type: type)] : results
        case "control_request":
            let request = object["request"] as? [String: Any] ?? [:]
            guard let parsed = PermissionRequest(requestId: object["request_id"] as? String ?? "", request: request) else {
                return [.ignored(type: "control_request.\(request["subtype"] as? String ?? "")")]
            }
            return [.permissionRequest(parsed)]
        case "control_cancel_request":
            guard let id = object["request_id"] as? String, !id.isEmpty else { return [.ignored(type: type)] }
            return [.permissionCancelled(id: id)]
        case "rate_limit_event":
            return [.usage(RateLimit(info: object["rate_limit_info"] as? [String: Any]))]
        case "result":
            let denials = (object["permission_denials"] as? [[String: Any]] ?? [])
                .compactMap { $0["tool_name"] as? String }
            return [.result(
                sessionId: object["session_id"] as? String ?? "",
                text: object["result"] as? String ?? (object["errors"] as? [String])?.first ?? "",
                isError: object["is_error"] as? Bool ?? false,
                denials: denials
            )]
        default:
            return [.ignored(type: type)]
        }
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func decodeContentItem(_ item: [String: Any]) -> [ClaudeEvent] {
        switch item["type"] as? String {
        case "thinking":
            return [.thinking]
        case "text":
            return [.text(item["text"] as? String ?? "")]
        case "tool_use":
            let input = item["input"] as? [String: Any] ?? [:]
            let first = input.keys.sorted().lazy.compactMap { input[$0] as? String }.first ?? ""
            let name = item["name"] as? String ?? ""
            var events: [ClaudeEvent] = [.toolUse(name: name, summary: String(first.prefix(summaryLimit)))]
            if name == "Bash", let command = input["command"] as? String, let id = item["id"] as? String {
                let paths = SentFiles.enviarFiles(in: command)
                if !paths.isEmpty { events.append(.fileSend(toolUseId: id, paths: paths)) }
            }
            return events
        default:
            return [.ignored(type: "assistant.\(item["type"] as? String ?? "")")]
        }
    }
}
