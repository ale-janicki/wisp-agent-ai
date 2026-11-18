import Foundation
import Testing
@testable import WispCore

/// Lines recorded from Claude Code 2.1.327 (`-p --input-format stream-json --permission-prompt-tool stdio`), paths scrubbed.
@Suite struct PermissionTests {
    private func fixtureEvents() throws -> [ClaudeEvent] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/permission-requests", withExtension: "jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").flatMap { ClaudeStreamDecoder.decode(line: String($0)) }
    }

    private func requests() throws -> [PermissionRequest] {
        try fixtureEvents().compactMap { if case .permissionRequest(let request) = $0 { return request } else { return nil } }
    }

    @Test func decodesTheThreeRecordedRequests() throws {
        let found = try requests()
        #expect(found.map(\.toolName) == ["Bash", "Write", "WebFetch"])
        #expect(found.map(\.summary) == ["rodar touch probe1", "escrever /tmp/wisp-scratch/notes.txt", "abrir https://example.com"])
        #expect(found[0].id == "60b7088a-a770-4ca8-b509-34df85ee1490")
        #expect(found[0].toolUseId == "toolu_0119S42dja9dtfk53vCGodgb")
        #expect(found[0].detail == "Create empty file probe1\n\ntouch probe1")
    }

    @Test func onlySettingsRulesCountAsAlways() throws {
        let found = try requests()
        #expect(found[0].canPersist)
        #expect(found[0].persistRules == ["Bash(touch probe1 *)"])
        #expect(!found[1].canPersist, "Write only offers setMode acceptEdits for the session")
        #expect(found[2].persistRules == ["WebFetch(domain:example.com)"])
    }

    @Test func initReportsTheMode() throws {
        #expect(try fixtureEvents().contains(.permissionMode("default")))
    }

    @Test func otherControlRequestsAreIgnored() {
        let line = #"{"type":"control_request","request_id":"r","request":{"subtype":"hook_callback"}}"#
        #expect(ClaudeStreamDecoder.decode(line: line) == [.ignored(type: "control_request.hook_callback")])
        #expect(ClaudeStreamDecoder.decode(line: #"{"type":"control_cancel_request","request_id":"r"}"#) == [.permissionCancelled(id: "r")])
    }

    @Test func homeShowsAsTilde() {
        let summary = PermissionRequest.summary(tool: "Edit", input: ["file_path": "/Users/u/notes.md"], home: "/Users/u")
        #expect(summary == "editar ~/notes.md")
        #expect(PermissionRequest.summary(tool: "mcp__x__do", input: ["q": "a\n b"], home: "/h") == "usar mcp__x__do: a b")
        #expect(PermissionRequest.summary(tool: "Bash", input: ["command": String(repeating: "x", count: 300)], home: "/h").count == 120)
    }

    private func line(_ data: Data) throws -> [String: Any] {
        #expect(data.last == 0x0A)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func allowEchoesTheInput() throws {
        let request = try requests()[0]
        let object = try line(ClaudeControl.response(to: request, .allow))
        #expect(object["type"] as? String == "control_response")
        let response = try #require(object["response"] as? [String: Any])
        #expect(response["subtype"] as? String == "success")
        #expect(response["request_id"] as? String == request.id)
        let answer = try #require(response["response"] as? [String: Any])
        #expect(answer["behavior"] as? String == "allow")
        #expect((answer["updatedInput"] as? [String: Any])?["command"] as? String == "touch probe1")
        #expect(answer["updatedPermissions"] == nil)
    }

    @Test func alwaysSendsOnlyTheRules() throws {
        let request = try requests()[0]
        let answer = try #require((try line(ClaudeControl.response(to: request, .allowAlways))["response"] as? [String: Any])?["response"] as? [String: Any])
        let persisted = try #require(answer["updatedPermissions"] as? [[String: Any]])
        #expect(persisted.map { $0["type"] as? String } == ["addRules"])
        #expect(persisted.first?["destination"] as? String == "localSettings")
    }

    @Test func denyCarriesAMessage() throws {
        let request = try requests()[1]
        let answer = try #require((try line(ClaudeControl.response(to: request, .deny))["response"] as? [String: Any])?["response"] as? [String: Any])
        #expect(answer["behavior"] as? String == "deny")
        #expect(answer["message"] as? String == ClaudeControl.denyMessage)
        #expect(answer["updatedInput"] == nil)
    }

    // MARK: Reducer

    private func reduce(_ state: inout ConversationState, _ events: [ClaudeEvent]) {
        for event in events { ConversationReducer.reduce(&state, .claude(event), statusPrefix: nil) }
    }

    @Test func requestsQueueAndTheTurnWaits() throws {
        let found = try requests()
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "oi")
        reduce(&state, [.toolUse(name: "Bash", summary: "touch probe1"), .permissionRequest(found[0]), .permissionRequest(found[1])])
        #expect(state.approvals.map(\.id) == [found[0].id, found[1].id])
        #expect(state.phase == .thinking(step: ConversationReducer.awaitingApprovalStep))
        reduce(&state, [.toolUse(name: "Write", summary: "x"), .permissionRequest(found[0])])
        #expect(state.approvals.count == 2, "a repeated request id is not queued twice")
        #expect(state.phase == .thinking(step: ConversationReducer.awaitingApprovalStep), "a tool row does not hide the wait")

        ConversationReducer.approvalAnswered(&state, id: found[0].id, decision: .allow)
        #expect(state.approvals.map(\.id) == [found[1].id])
        #expect(state.phase == .thinking(step: ConversationReducer.awaitingApprovalStep))
        ConversationReducer.approvalAnswered(&state, id: found[1].id, decision: .deny)
        #expect(state.approvals.isEmpty)
        #expect(state.phase == .thinking(step: nil))
        #expect(state.messages.last?.text == "você negou: escrever /tmp/wisp-scratch/notes.txt")
    }

    @Test func userDenialGetsNoSettingsHint() throws {
        let events = try fixtureEvents()
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "oi")
        let request = try requests()[0]
        reduce(&state, [.permissionRequest(request)])
        ConversationReducer.approvalAnswered(&state, id: request.id, decision: .deny)
        reduce(&state, events.filter { if case .result = $0 { return true } else { return false } })
        #expect(!state.messages.contains { $0.text.contains("libere em") })
        #expect(state.phase == .idle)
        #expect(state.userDenials.isEmpty)
    }

    @Test func configDenialKeepsTheHint() {
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "oi")
        reduce(&state, [.result(sessionId: "s", text: "ok", isError: false, denials: ["Bash"])])
        #expect(state.messages.contains { $0.text == "negado: Bash — libere em ~/.claude/settings.json" })
    }

    @Test func cancelAndExitClearTheQueue() throws {
        let found = try requests()
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "oi")
        reduce(&state, [.permissionRequest(found[0]), .permissionCancelled(id: found[0].id)])
        #expect(state.approvals.isEmpty)
        #expect(state.phase == .thinking(step: nil))
        reduce(&state, [.permissionRequest(found[1])])
        ConversationReducer.reduce(&state, .exited(code: 1, stderrTail: ""), statusPrefix: nil)
        #expect(state.approvals.isEmpty)
    }

    // MARK: Setting

    @Test func profileWinsOverClaude() {
        #expect(PermissionSetting.resolve(profileMode: "auto", claudeDefaultMode: "bypassPermissions") == PermissionSetting(choice: .auto, source: .profile))
        #expect(PermissionSetting.resolve(profileMode: nil, claudeDefaultMode: "auto") == PermissionSetting(choice: .auto, source: .claude("auto")))
        #expect(PermissionSetting.resolve(profileMode: nil, claudeDefaultMode: "acceptEdits") == PermissionSetting(choice: nil, source: .claude("acceptEdits")))
        #expect(PermissionSetting.resolve(profileMode: "weird", claudeDefaultMode: nil) == PermissionSetting(choice: .ask, source: .standard))
        #expect(PermissionSetting.cliMode(profileMode: "manual") == "default")
        #expect(PermissionSetting.cliMode(profileMode: nil) == nil)
        #expect(PermissionSetting.cliMode(profileMode: "plan") == nil)
        #expect(PermissionSetting.resolve(profileMode: "default", wispMode: "bypassPermissions", claudeDefaultMode: "auto")
            == PermissionSetting(choice: .bypass, source: .wisp))
        #expect(PermissionSetting.cliMode(profileMode: "default", wispMode: "auto") == "auto")
        #expect(PermissionSetting.cliMode(profileMode: "default", wispMode: "junk") == "default")
    }

    @Test func readsClaudeDefaultMode() {
        #expect(PermissionSetting.claudeDefaultMode(settings: Data(#"{"permissions":{"defaultMode":"auto","allow":[]}}"#.utf8)) == "auto")
        #expect(PermissionSetting.claudeDefaultMode(settings: Data(#"{"permissions":{}}"#.utf8)) == nil)
        #expect(PermissionSetting.claudeDefaultMode(settings: Data("nope".utf8)) == nil)
        #expect(PermissionSetting.claudeDefaultMode(settings: nil) == nil)
    }

    @Test func writingKeepsEveryOtherKey() throws {
        let before = Data(#"{"persona":{"name":"Ze","language":"pt-BR"},"agent":{"cwd":"~/x","model":"opus"},"blocks":{"tasks":{"file":"/t"}}}"#.utf8)
        let after = try PermissionSetting.profileData(updating: before, mode: .bypass)
        let profile = try JSONDecoder().decode(Profile.self, from: after)
        #expect(profile.agent == AgentConfig(cwd: "~/x", model: "opus", permissionMode: "bypassPermissions"))
        #expect(profile.persona.name == "Ze")
        #expect(profile.blocks?.tasks?.file == "/t")
        let fresh = try JSONDecoder().decode(Profile.self, from: PermissionSetting.profileData(updating: nil, mode: .auto))
        #expect(fresh.agent.permissionMode == "auto")
        #expect(fresh.agent.cwd == "~")
        #expect(throws: PermissionSetting.WriteError.notAnObject) { try PermissionSetting.profileData(updating: Data("[]".utf8), mode: .ask) }
    }
}
