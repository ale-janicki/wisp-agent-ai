import XCTest
@testable import WispCore

final class LocalSessionTests: XCTestCase {
    private func script(_ body: String) throws -> (dir: URL, script: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-ls-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("wisp")
        try "#!/bin/sh\necho \"$@\" >> \(dir.path)/argv\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (dir, script)
    }

    private func cardScript(tool: String) -> String {
        """
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"c1","model":"qwen3:8b","apiKeySource":"none","permissionMode":"default","engine":"local","tier":"pequeno"}'
        printf '%s\\n' '{"type":"control_request","request_id":"req_1","request":{"subtype":"can_use_tool","tool_name":"\(tool)","display_name":"\(tool)","input":{"to":["a@b.c"],"subject":"Oi","body":"x"},"description":"\(tool): a@b.c","permission_suggestions":[],"tool_use_id":"toolu_local_a"}}'
        read line
        echo "$line" >> ANSWERS_PLACEHOLDER
        case "$line" in *'"behavior":"allow"'*) R=feito;; *) R=negado;; esac
        printf '%s\\n' "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"session_id\\":\\"c1\\",\\"result\\":\\"$R\\",\\"is_error\\":false,\\"permission_denials\\":[],\\"engine\\":\\"local\\",\\"model\\":\\"qwen3:8b\\"}"
        """
    }

    private func run(_ session: LocalSession, decision: PermissionDecision?) async throws -> [SessionEvent] {
        try await session.start()
        try await session.send("oi")
        var seen: [SessionEvent] = []
        let stream = session.events
        let collector = Task { () -> [SessionEvent] in
            var out: [SessionEvent] = []
            for await event in stream {
                out.append(event)
                if case .claude(.permissionRequest(let request)) = event, let decision {
                    try? await session.respond(to: request, decision)
                }
                if case .claude(.result) = event { break }
            }
            return out
        }
        let timeout = Task { try await Task.sleep(for: .seconds(15)); collector.cancel() }
        seen = await collector.value
        timeout.cancel()
        await session.stop()
        return seen
    }

    func testATurnRunsTheRuntimeCommandWithStdioApprovalsAndDecodesTheStream() async throws {
        let made = try script(cardScript(tool: "write_file").replacingOccurrences(of: "ANSWERS_PLACEHOLDER", with: "/dev/null"))
        defer { try? FileManager.default.removeItem(at: made.dir) }
        let session = LocalSession(executable: made.script, cwd: made.dir, conversation: "c1", mode: "auto")
        XCTAssertTrue(session.routesApprovals)
        XCTAssertEqual(session.kind, .local)
        let events = try await run(session, decision: .allow)
        XCTAssertTrue(events.contains(.claude(.initialized(sessionId: "c1", model: "qwen3:8b", subscription: true))))
        XCTAssertEqual(events.last, .claude(.result(sessionId: "c1", text: "feito", isError: false, denials: [])))
        let argv = try String(contentsOf: made.dir.appendingPathComponent("argv"), encoding: .utf8)
        XCTAssertEqual(
            argv, "local chat --message=oi --approvals stdio --no-record --recorded --surface app --mode auto --conversation c1\n")
    }

    func testTheCardAnswerReachesTheEngineAllowedAndDenied() async throws {
        for (decision, word) in [(PermissionDecision.allow, "feito"), (.deny, "negado")] {
            let made = try script(cardScript(tool: "write_file").replacingOccurrences(of: "ANSWERS_PLACEHOLDER", with: "ANSWERS"))
            defer { try? FileManager.default.removeItem(at: made.dir) }
            let events = try await run(LocalSession(executable: made.script, cwd: made.dir, conversation: "c1"), decision: decision)
            guard case .claude(.permissionRequest(let request))? = events.first(where: { if case .claude(.permissionRequest) = $0 { true } else { false } })
            else { return XCTFail("no card: \(events)") }
            XCTAssertEqual(request.id, "req_1")
            XCTAssertEqual(request.toolName, "write_file")
            XCTAssertEqual(events.last, .claude(.result(sessionId: "c1", text: word, isError: false, denials: [])))
            let answer = try String(contentsOf: made.dir.appendingPathComponent("ANSWERS"), encoding: .utf8)
            XCTAssertTrue(answer.contains("\"request_id\":\"req_1\""))
            XCTAssertTrue(answer.contains("\"behavior\":\"\(decision == .allow ? "allow" : "deny")\""))
        }
    }

    func testAnEmailSendIsAskedThroughTheSameCard() async throws {
        let made = try script(cardScript(tool: "email_send").replacingOccurrences(of: "ANSWERS_PLACEHOLDER", with: "/dev/null"))
        defer { try? FileManager.default.removeItem(at: made.dir) }
        let events = try await run(LocalSession(executable: made.script, cwd: made.dir, conversation: "c1"), decision: .allow)
        let cards = events.compactMap { event -> PermissionRequest? in
            if case .claude(.permissionRequest(let request)) = event { request } else { nil }
        }
        XCTAssertEqual(cards.map(\.toolName), ["email_send"])
        XCTAssertEqual(events.last, .claude(.result(sessionId: "c1", text: "feito", isError: false, denials: [])))
    }

    func testAProcessThatFailsWithoutAResultBecomesAnErrorResultWithItsReason() async throws {
        let made = try script("echo '{\"type\":\"error\",\"message\":\"o modelo x não está baixado\"}'\nexit 1")
        defer { try? FileManager.default.removeItem(at: made.dir) }
        let events = try await run(LocalSession(executable: made.script, cwd: made.dir, conversation: "c1"), decision: nil)
        XCTAssertEqual(events.last, .claude(.result(sessionId: "", text: "o modelo x não está baixado", isError: true, denials: [])))
        let silent = try script("echo boom >&2\nexit 2")
        defer { try? FileManager.default.removeItem(at: silent.dir) }
        let again = try await run(LocalSession(executable: silent.script, cwd: silent.dir, conversation: "c1"), decision: nil)
        XCTAssertEqual(again.last, .claude(.result(sessionId: "", text: "boom", isError: true, denials: [])))
    }

    func testTwoTurnsRunOneAfterTheOtherAndAnAnswerWithNoTurnIsRefused() async throws {
        let made = try script("""
        printf '%s\\n' '{"type":"result","subtype":"success","session_id":"c1","result":"ok","is_error":false,"permission_denials":[]}'
        """)
        defer { try? FileManager.default.removeItem(at: made.dir) }
        let session = LocalSession(executable: made.script, cwd: made.dir, conversation: "c1")
        try await session.start()
        try await session.send("um")
        try await session.send("dois")
        var results = 0
        for await event in session.events {
            if case .claude(.result) = event { results += 1 }
            if results == 2 { break }
        }
        XCTAssertEqual(results, 2)
        let argv = try String(contentsOf: made.dir.appendingPathComponent("argv"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(argv.count, 2)
        try await Task.sleep(for: .milliseconds(200))
        do {
            try await session.respond(to: PermissionRequest(id: "r", toolName: "x", summary: "x", detail: "x"), .allow)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentError, .notRunning)
        }
        await session.stop()
    }

    func testAMissingRuntimeBinaryFailsToStart() async throws {
        let session = LocalSession(executable: URL(fileURLWithPath: "/nope/wisp"), cwd: FileManager.default.temporaryDirectory, conversation: "c")
        do {
            try await session.start()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentError, .notRunning)
        }
    }

    func testTheFactoryBuildsALocalSession() {
        let launch = EngineLaunch(
            kind: .local, executable: URL(fileURLWithPath: "/x/wisp"), cwd: URL(fileURLWithPath: "/tmp"), claudePermissionMode: "auto",
            conversation: "abc")
        let session = EngineFactory.make(launch)
        XCTAssertEqual(session.kind, .local)
        XCTAssertTrue(session.routesApprovals)
    }

    func testAMessageThatStartsWithADashStaysOneArgument() {
        XCTAssertEqual(
            LocalSession.arguments(text: "-5 graus", conversation: "c", mode: "default").first { $0.hasPrefix("--message") }, "--message=-5 graus")
    }
}
