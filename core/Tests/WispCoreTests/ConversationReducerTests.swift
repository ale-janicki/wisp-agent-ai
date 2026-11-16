import Testing
@testable import WispCore

@Suite struct ConversationReducerTests {
    private func reduce(_ state: inout ConversationState, _ events: [SessionEvent], prefix: String? = "STATUS ·") {
        for event in events { ConversationReducer.reduce(&state, event, statusPrefix: prefix) }
    }

    @Test func initSetsSessionId() {
        var state = ConversationState()
        reduce(&state, [.claude(.initialized(sessionId: "abc", model: "m", subscription: true))])
        #expect(state.sessionId == "abc")
        #expect(state.subscription == true)
    }

    @Test func textAppendsToCurrentAssistantMessage() {
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "oi")
        reduce(&state, [.claude(.text("Olá")), .claude(.text("mundo"))])
        #expect(state.messages.map(\.role) == [.user, .assistant])
        #expect(state.messages.last?.text == "Olá\n\nmundo")
    }

    @Test func toolUseSetsThinkingStep() {
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "oi")
        reduce(&state, [.claude(.toolUse(name: "Bash", summary: "ls -la"))])
        #expect(state.phase == .thinking(step: "Bash: ls -la"))
        #expect(state.messages.last?.role == .tool)
        #expect(state.messages.last?.text == "Bash: ls -la")
    }

    @Test func resultSplitsStatus() {
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "oi")
        reduce(&state, [
            .claude(.text("rascunho")),
            .claude(.result(sessionId: "s1", text: "Tudo certo\nSTATUS · 2 alertas", isError: false, denials: [])),
        ])
        #expect(state.messages.last?.text == "Tudo certo")
        #expect(state.status == "2 alertas")
        #expect(state.phase == .idle)
        #expect(state.sessionId == "s1")
    }

    @Test func exitedMidReplyFails() {
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "oi")
        reduce(&state, [.exited(code: 1, stderrTail: "boom")])
        guard case .failed(let reason) = state.phase else { Issue.record("not failed"); return }
        #expect(reason.contains("boom"))
    }

    @Test func denialsShownAsSystemMessage() {
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "oi")
        reduce(&state, [.claude(.result(sessionId: "s", text: "ok", isError: false, denials: ["Bash"]))])
        #expect(state.messages.contains { $0.role == .system && $0.text == "negado: Bash — libere em ~/.claude/settings.json" })
    }

    @Test func errorResultFails() {
        var state = ConversationState()
        reduce(&state, [.claude(.result(sessionId: "s", text: "", isError: true, denials: []))])
        #expect(state.phase == .failed("erro"))
    }

    @Test func usageAndNoiseEvents() {
        var state = ConversationState()
        reduce(&state, [.claude(.usage(RateLimit(fiveHour: RateLimitWindow(utilization: 0.4)))), .claude(.ignored(type: "x")), .claude(.malformed("{"))])
        #expect(state.fiveHour == 0.4)
        #expect(state.messages.isEmpty)
        reduce(&state, [.claude(.thinking)])
        #expect(state.phase == .thinking(step: nil))
        #expect(state.messages.isEmpty)
    }

    @Test func userSendAppendsAndThinks() {
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "oi")
        #expect(state.messages.map(\.text) == ["oi"])
        #expect(state.phase == .thinking(step: nil))
    }

    @Test func authErrorsAreRecognized() {
        for text in ["Invalid API key · Please run /login", "Not logged in", "API Error: 401", "OAuth token expired", "Authentication failed"] {
            #expect(ConversationReducer.isAuthError(text), "\(text)")
        }
    }

    @Test func otherErrorsAreNotAuth() {
        for text in ["", "erro", "API Error: 529 overloaded", "context length exceeded", "tool crashed"] {
            #expect(!ConversationReducer.isAuthError(text), "\(text)")
        }
    }

    @Test func queuedTurnStaysThinkingUntilLastResult() {
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "um")
        ConversationReducer.userSent(&state, text: "dois")
        #expect(state.pendingTurns == 2)
        reduce(&state, [.claude(.result(sessionId: "s", text: "a", isError: false, denials: []))])
        #expect(state.phase == .thinking(step: nil))
        #expect(state.pendingTurns == 1)
        reduce(&state, [.claude(.result(sessionId: "s", text: "b", isError: false, denials: []))])
        #expect(state.phase == .idle)
        #expect(state.pendingTurns == 0)
    }

    @Test func exitedResetsPendingTurns() {
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "um")
        ConversationReducer.userSent(&state, text: "dois")
        reduce(&state, [.exited(code: 1, stderrTail: "")])
        #expect(state.pendingTurns == 0)
        #expect(state.phase == .failed("claude encerrou (código 1)"))
    }

    @Test func failedDeliverThenResendReturnsToIdle() {
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "um")
        ConversationReducer.sessionDiscarded(&state)
        #expect(state.pendingTurns == 0)
        ConversationReducer.userSent(&state, text: "dois")
        reduce(&state, [.claude(.result(sessionId: "s", text: "ok", isError: false, denials: []))])
        #expect(state.phase == .idle)
        #expect(state.pendingTurns == 0)
    }
}
