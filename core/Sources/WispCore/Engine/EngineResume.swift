import Foundation

public struct ResumePlan: Equatable, Sendable {
    public var resume: String?
    public var prime: Bool
    public var switched: Bool
    public var linkReason: String
    public var dropClaudeSession: Bool
}

public enum EngineResume {
    public static func plan(kind: EngineKind, lastEngine: String?, claudeSession: String?, codexSession: String?, lost: Bool) -> ResumePlan {
        let switched = lastEngine != nil && lastEngine != kind.rawValue
        if kind == .local {
            return ResumePlan(resume: nil, prime: false, switched: switched, linkReason: "new", dropClaudeSession: false)
        }
        let known = kind == .codex ? codexSession : claudeSession
        let missing = lastEngine != nil && known == nil
        guard lost || switched || missing else {
            return ResumePlan(resume: known, prime: false, switched: false, linkReason: "new", dropClaudeSession: false)
        }
        return ResumePlan(
            resume: nil, prime: true, switched: switched, linkReason: "rebuilt",
            dropClaudeSession: kind == .claude && (switched || lost))
    }
}
