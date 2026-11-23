import Foundation

public struct ConversationMessage: Equatable, Identifiable, Sendable {
    public enum Role: Sendable, Equatable { case user, assistant, system, tool }

    public let id: UUID
    public var role: Role
    public var text: String
    public var time: Date?
    public var files: [String]

    public init(role: Role, text: String, id: UUID = UUID(), time: Date? = nil, files: [String] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.time = time
        self.files = files
    }
}

public struct ConversationState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case thinking(step: String?)
        case failed(String)
    }

    public var messages: [ConversationMessage] = []
    public var phase: Phase = .idle
    public var sessionId: String?
    public var status: String?
    public var rateLimit: RateLimit?
    public var fiveHour: Double? { rateLimit?.fiveHour?.utilization }
    public var subscription: Bool?
    public var pendingTurns = 0
    public var approvals: [PermissionRequest] = []
    public var permissionMode: String?
    public var userDenials: [String] = []
    public var hookBlocks = 0
    public var pendingSends: [String: [String]] = [:]
    public var turnSentFiles: [String] = []
    public var sentToTelegram: [String] = []
    public var engineName = "claude"

    public init() {}
}

public enum ConversationReducer {
    public static func userSent(_ s: inout ConversationState, text: String, id: UUID = UUID(), time: Date = Date()) {
        s.messages.append(ConversationMessage(role: .user, text: text, id: id, time: time))
        s.status = nil
        s.pendingTurns += 1
        s.phase = .thinking(step: nil)
    }

    public static func sessionDiscarded(_ s: inout ConversationState) {
        s.pendingTurns = 0
        s.approvals = []
        s.userDenials = []
        clearTurnFiles(&s)
    }

    private static func clearTurnFiles(_ s: inout ConversationState) {
        s.hookBlocks = 0
        s.pendingSends = [:]
        s.turnSentFiles = []
    }

    public static func processRestarted(_ s: inout ConversationState) {
        s.approvals = []
        s.userDenials = []
        clearTurnFiles(&s)
    }

    public static let awaitingApprovalStep = "esperando tua aprovação"

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

    /// `pendingAfterResult` is what the runtime's ledger says is still waiting once a `result`
    /// closes its messages; the reducer makes no engine decision.
    public static func reduce(
        _ s: inout ConversationState, _ e: SessionEvent, statusPrefix: String?, pendingAfterResult: Int = 0
    ) {
        switch e {
        case .claude(let event):
            reduce(&s, event, statusPrefix: statusPrefix, pendingAfterResult: pendingAfterResult)
        case .exited(let code, let stderrTail):
            let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            s.pendingTurns = 0
            s.approvals = []
            s.userDenials = []
            clearTurnFiles(&s)
            let name = s.engineName
            s.phase = .failed(tail.isEmpty ? "\(name) encerrou (código \(code))" : "\(name) encerrou (código \(code)): \(tail)")
        }
    }

    private static func reduce(
        _ s: inout ConversationState, _ event: ClaudeEvent, statusPrefix: String?, pendingAfterResult: Int
    ) {
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
        case .text(let rawText):
            if s.phase == .idle { s.phase = .thinking(step: nil) }
            let text = TelegramHTML.markdown(rawText)
            if let last = s.messages.last, last.role == .assistant {
                s.messages[s.messages.count - 1].text = last.text + "\n\n" + text
            } else {
                s.messages.append(ConversationMessage(role: .assistant, text: text))
            }
        case .toolUse(let name, let summary):
            let step = summary.isEmpty ? name : "\(name): \(summary)"
            s.messages.append(ConversationMessage(role: .tool, text: step))
            if s.approvals.isEmpty { s.phase = .thinking(step: step) }
        case .fileSend(let id, let paths):
            s.pendingSends[id] = paths
        case .toolResult(let id, let isError, let text):
            let paths = s.pendingSends.removeValue(forKey: id)
            if !isError, let paths {
                for path in paths where !s.turnSentFiles.contains(path) { s.turnSentFiles.append(path) }
            } else if isError, let reason = ToolBlock.hookReason(in: text) {
                s.hookBlocks += 1
                s.messages.append(ConversationMessage(role: .system, text: ToolBlock.notice(reason: reason)))
            }
        case .usage(let rateLimit):
            s.rateLimit = rateLimit
        case .result(let sessionId, let text, let isError, let denials):
            if !sessionId.isEmpty { s.sessionId = sessionId }
            s.pendingTurns = max(0, pendingAfterResult)
            s.approvals = []
            var denials = denials
            for tool in s.userDenials {
                if let index = denials.firstIndex(of: tool) { denials.remove(at: index) }
            }
            s.userDenials = []
            denials.removeFirst(min(s.hookBlocks, denials.count))
            let sent = s.turnSentFiles
            clearTurnFiles(&s)
            s.sentToTelegram = sent
            if isError {
                s.pendingTurns = 0
                s.phase = .failed(text.isEmpty ? "erro" : text)
                return
            }
            let split = ReplyFormatter.split(text, statusPrefix: statusPrefix)
            let parts = (body: TelegramHTML.markdown(split.body), status: split.status)
            let cards = SentFiles.cards(sent: sent, replyText: split.body)
            if let last = s.messages.last, last.role == .assistant {
                if parts.body.isEmpty, cards.isEmpty {
                    s.messages.removeLast()
                } else {
                    s.messages[s.messages.count - 1].text = parts.body
                    s.messages[s.messages.count - 1].files = cards
                }
            } else if !parts.body.isEmpty || !cards.isEmpty {
                s.messages.append(ConversationMessage(role: .assistant, text: parts.body, files: cards))
            }
            for tool in denials {
                s.messages.append(ConversationMessage(
                    role: .system,
                    text: "negado: \(tool) — libere em ~/.claude/settings.json"
                ))
            }
            s.status = parts.status
            s.phase = s.pendingTurns == 0 ? .idle : .thinking(step: nil)
        case .engineSession, .ignored, .malformed:
            break
        }
    }
}
