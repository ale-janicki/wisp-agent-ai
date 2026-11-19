public enum ClaudeEvent: Sendable, Equatable {
    case initialized(sessionId: String, model: String, subscription: Bool)
    case permissionMode(String)
    case thinking
    case text(String)
    case toolUse(name: String, summary: String)
    case fileSend(toolUseId: String, paths: [String])
    case toolResult(toolUseId: String, isError: Bool, text: String)
    case permissionRequest(PermissionRequest)
    case permissionCancelled(id: String)
    case usage(RateLimit)
    case result(sessionId: String, text: String, isError: Bool, denials: [String])
    case ignored(type: String)
    case malformed(String)
}
