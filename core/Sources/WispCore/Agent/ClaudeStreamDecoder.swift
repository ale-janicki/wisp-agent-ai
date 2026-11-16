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
            return [.initialized(
                sessionId: object["session_id"] as? String ?? "",
                model: object["model"] as? String ?? "",
                subscription: object["apiKeySource"] as? String == "none"
            )]
        case "assistant":
            let message = object["message"] as? [String: Any]
            let items = message?["content"] as? [[String: Any]] ?? []
            return items.map(decodeContentItem)
        case "rate_limit_event":
            return [.usage(RateLimit(info: object["rate_limit_info"] as? [String: Any]))]
        case "result":
            let denials = (object["permission_denials"] as? [[String: Any]] ?? [])
                .compactMap { $0["tool_name"] as? String }
            return [.result(
                sessionId: object["session_id"] as? String ?? "",
                text: object["result"] as? String ?? "",
                isError: object["is_error"] as? Bool ?? false,
                denials: denials
            )]
        default:
            return [.ignored(type: type)]
        }
    }

    private static func decodeContentItem(_ item: [String: Any]) -> ClaudeEvent {
        switch item["type"] as? String {
        case "thinking":
            return .thinking
        case "text":
            return .text(item["text"] as? String ?? "")
        case "tool_use":
            let input = item["input"] as? [String: Any] ?? [:]
            let first = input.keys.sorted().lazy.compactMap { input[$0] as? String }.first ?? ""
            return .toolUse(name: item["name"] as? String ?? "", summary: String(first.prefix(summaryLimit)))
        default:
            return .ignored(type: "assistant.\(item["type"] as? String ?? "")")
        }
    }
}
