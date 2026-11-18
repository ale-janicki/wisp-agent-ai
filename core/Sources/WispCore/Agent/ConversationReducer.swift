import Foundation

public struct ConversationMessage: Equatable, Identifiable, Sendable {
    public enum Role: Sendable, Equatable { case user, assistant, system, tool }

    public let id: UUID
    public var role: Role
    public var text: String
    public var time: Date?

    public init(role: Role, text: String, id: UUID = UUID(), time: Date? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.time = time
    }
}

public struct ConversationState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case thinking(step: String?)
        case failed(String)
        case held(String)
    }

    public var messages: [ConversationMessage] = []
    public var phase: Phase = .idle
    public var sessionId: String?
    public var status: String?
    public var rateLimit: RateLimit?
    public var fiveHour: Double? { rateLimit?.fiveHour?.utilization }
    public var subscription: Bool?
    public var pendingTurns = 0
    /// Tool calls the CLI holds for the user, oldest first; the first one is on screen.
    public var approvals: [PermissionRequest] = []
    /// The mode the CLI reported at init.
    public var permissionMode: String?
    /// Tools the user denied this turn; the result lists them as denials too, and they need no settings hint.
    public var userDenials: [String] = []

    public init() {}
}

public enum ConversationReducer {
    public static func userSent(_ s: inout ConversationState, text: String, id: UUID = UUID(), time: Date = Date()) {
        s.messages.append(ConversationMessage(role: .user, text: text, id: id, time: time))
        s.status = nil
        s.pendingTurns += 1
        if case .held = s.phase { return }
        s.phase = .thinking(step: nil)
    }

    /// The message waits in the outbox for the bot; later messages of the conversation queue behind it.
    public static func held(_ s: inout ConversationState, reason: String) {
        s.phase = .held(reason)
    }

    public static func sessionDiscarded(_ s: inout ConversationState) {
        s.pendingTurns = 0
        s.approvals = []
        s.userDenials = []
    }

    public static let awaitingApprovalStep = "esperando tua aprovação"

    /// The user answered the request on screen (or one queued behind it); the turn goes on.
    public static func approvalAnswered(_ s: inout ConversationState, id: String, decision: PermissionDecision) {
        guard let index = s.approvals.firstIndex(where: { $0.id == id }) else { return }
        let request = s.approvals.remove(at: index)
        if !decision.allows {
            s.userDenials.append(request.toolName)
            s.messages.append(ConversationMessage(role: .system, text: "você negou: \(request.summary)"))
        }
        resumeAfterApprovals(&s)
    }

    private static func resumeAfterApprovals(_ s: inout ConversationState) {
        guard s.approvals.isEmpty, s.phase == .thinking(step: awaitingApprovalStep) else { return }
        s.phase = .thinking(step: nil)
    }

    private static let authMarkers = ["invalid api key", "/login", "401", "authentication", "not logged in", "oauth"]

    public static func isAuthError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return authMarkers.contains { lowered.contains($0) }
    }

    public static func reduce(_ s: inout ConversationState, _ e: SessionEvent, statusPrefix: String?) {
        switch e {
        case .claude(let event):
            reduce(&s, event, statusPrefix: statusPrefix)
        case .exited(let code, let stderrTail):
            let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            s.pendingTurns = 0
            s.approvals = []
            s.userDenials = []
            s.phase = .failed(tail.isEmpty ? "claude encerrou (código \(code))" : "claude encerrou (código \(code)): \(tail)")
        }
    }

    private static func reduce(_ s: inout ConversationState, _ event: ClaudeEvent, statusPrefix: String?) {
        switch event {
        case .initialized(let sessionId, _, let subscription):
            if !sessionId.isEmpty { s.sessionId = sessionId }
            s.subscription = subscription
        case .permissionMode(let mode):
            s.permissionMode = mode
        case .permissionRequest(let request):
            if !s.approvals.contains(where: { $0.id == request.id }) { s.approvals.append(request) }
            s.phase = .thinking(step: awaitingApprovalStep)
        case .permissionCancelled(let id):
            s.approvals.removeAll { $0.id == id }
            resumeAfterApprovals(&s)
        case .thinking:
            if s.phase == .idle { s.phase = .thinking(step: nil) }
        case .text(let text):
            if let last = s.messages.last, last.role == .assistant {
                s.messages[s.messages.count - 1].text = last.text + "\n\n" + text
            } else {
                s.messages.append(ConversationMessage(role: .assistant, text: text))
            }
        case .toolUse(let name, let summary):
            let step = summary.isEmpty ? name : "\(name): \(summary)"
            s.messages.append(ConversationMessage(role: .tool, text: step))
            if s.approvals.isEmpty { s.phase = .thinking(step: step) }
        case .usage(let rateLimit):
            s.rateLimit = rateLimit
        case .result(let sessionId, let text, let isError, let denials):
            if !sessionId.isEmpty { s.sessionId = sessionId }
            s.pendingTurns = max(0, s.pendingTurns - 1)
            s.approvals = []
            var denials = denials
            for tool in s.userDenials {
                if let index = denials.firstIndex(of: tool) { denials.remove(at: index) }
            }
            s.userDenials = []
            if isError {
                s.pendingTurns = 0
                s.phase = .failed(text.isEmpty ? "erro" : text)
                return
            }
            let parts = ReplyFormatter.split(text, statusPrefix: statusPrefix)
            if let last = s.messages.last, last.role == .assistant {
                if parts.body.isEmpty {
                    s.messages.removeLast()
                } else {
                    s.messages[s.messages.count - 1].text = parts.body
                }
            } else if !parts.body.isEmpty {
                s.messages.append(ConversationMessage(role: .assistant, text: parts.body))
            }
            for tool in denials {
                s.messages.append(ConversationMessage(
                    role: .system,
                    text: "negado: \(tool) — libere em ~/.claude/settings.json"
                ))
            }
            s.status = parts.status
            s.phase = s.pendingTurns == 0 ? .idle : .thinking(step: nil)
        case .ignored, .malformed:
            break
        }
    }
}
