public enum ClaudeEvent: Sendable, Equatable {
    case initialized(sessionId: String, model: String, subscription: Bool)
    case thinking
    case text(String)
    case toolUse(name: String, summary: String)
    case usage(RateLimit)
    case result(sessionId: String, text: String, isError: Bool, denials: [String])
    case ignored(type: String)
    case malformed(String)
}
