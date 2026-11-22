import XCTest
@testable import WispCore

final class CodexEngineTests: XCTestCase {
    private static let thread = "0199a213-81c0-7800-8aa1-bbab2a035a53"

    private func contract(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cli/tests/fixtures/contract/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func decode(_ name: String) throws -> (events: [ClaudeEvent], decoder: CodexEventDecoder) {
        var decoder = CodexEventDecoder()
        var events: [ClaudeEvent] = []
        for line in try contract(name).split(separator: "\n") { events += decoder.decode(line: String(line)) }
        return (events, decoder)
    }

    func testDocumentedStreamDecodesToTheAppEventFormat() throws {
        let (events, decoder) = try decode("codex-exec-stream-from-docs.jsonl")
        XCTAssertEqual(decoder.threadId, Self.thread)
        XCTAssertTrue(events.contains(.initialized(sessionId: "", model: "", subscription: true)))
        XCTAssertTrue(events.contains(.engineSession(engine: "codex", id: Self.thread)))
        XCTAssertTrue(events.contains(.toolUse(name: "Bash", summary: "bash -lc ls")))
        XCTAssertTrue(events.contains(.toolResult(toolUseId: "item_1", isError: false, text: "docs\nsdk\nexamples\n")))
        XCTAssertTrue(events.contains(.toolUse(name: "wisp-email.email_list", summary: "")))
        XCTAssertTrue(events.contains(.toolUse(name: "Edit", summary: "/Users/rita/Wisp/brain/notas.md")))
        let reply = "Repo contains docs, sdk, and examples directories.\n\nSTATUS · teste · ok"
        XCTAssertTrue(events.contains(.text(reply)))
        XCTAssertEqual(events.last, .result(sessionId: "", text: reply, isError: false, denials: []))
    }

    func testFailedStreamBecomesAnErrorResult() throws {
        let (events, _) = try decode("codex-exec-failed-from-docs.jsonl")
        XCTAssertEqual(events.last, .result(sessionId: "", text: "stream disconnected before completion", isError: true, denials: []))
    }

    func testNonFatalErrorDoesNotFailACompletedTurn() throws {
        let (events, decoder) = try decode("codex-exec-nonfatal-error-from-docs.jsonl")
        XCTAssertEqual(events.last, .result(sessionId: "", text: "Done.", isError: false, denials: []))
        XCTAssertTrue(decoder.closing(exitCode: 0, stderrTail: "", resumed: false).isEmpty)
    }

    func testStreamWithoutCompletionIsClosedAsAnError() throws {
        let (events, decoder) = try decode("codex-exec-incomplete-from-docs.jsonl")
        XCTAssertFalse(events.contains { if case .result = $0 { true } else { false } })
        guard case .result(_, let text, true, _)? = decoder.closing(exitCode: 0, stderrTail: "", resumed: false).first
        else { return XCTFail("a stream that never completed must be an error") }
        XCTAssertEqual(text, CodexEventDecoder.incomplete)
    }

    func testReducerKeepsTheConversationIdentityAndShowsTheReply() throws {
        var state = ConversationState()
        state.sessionId = "conversation-1"
        ConversationReducer.userSent(&state, text: "oi")
        for event in try decode("codex-exec-stream-from-docs.jsonl").events {
            ConversationReducer.reduce(&state, .claude(event), statusPrefix: "STATUS")
        }
        XCTAssertEqual(state.sessionId, "conversation-1")
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.messages.last?.role, .assistant)
        XCTAssertEqual(state.messages.last?.text, "Repo contains docs, sdk, and examples directories.")
    }

    func testRunWithoutTurnOutcomeIsClosedByTheExitCode() {
        let decoder = CodexEventDecoder()
        XCTAssertEqual(
            decoder.closing(exitCode: 1, stderrTail: "boom", resumed: false),
            [.result(sessionId: "", text: "codex saiu com código 1: boom", isError: true, denials: [])])
        XCTAssertEqual(
            decoder.closing(exitCode: 0, stderrTail: "", resumed: false),
            [.result(sessionId: "", text: CodexEventDecoder.incomplete, isError: true, denials: [])])
        XCTAssertEqual(
            decoder.closing(exitCode: 1, stderrTail: "", resumed: true),
            [.result(sessionId: "", text: ConversationTranscript.codexLostSession, isError: true, denials: [])])
        guard case .result(_, let text, true, _)? = decoder.closing(exitCode: 1, stderrTail: "Not logged in", resumed: true).first
        else { return XCTFail("no result") }
        XCTAssertTrue(text.contains("codex login"))
        XCTAssertFalse(ConversationTranscript.isLostSession(text))
        XCTAssertTrue(ConversationTranscript.isLostSession(ConversationTranscript.codexLostSession))
    }

    func testPermissionChoicesMapToSandboxesAndNeverToFullAccess() {
        XCTAssertEqual(CodexCommand.sandboxArguments(.ask), ["--sandbox", "read-only"])
        XCTAssertEqual(CodexCommand.sandboxArguments(nil), ["--sandbox", "read-only"])
        XCTAssertEqual(CodexCommand.sandboxArguments(.auto), ["--sandbox", "workspace-write"])
        XCTAssertEqual(CodexCommand.sandboxArguments(.bypass), ["--sandbox", "workspace-write"])
        for choice in PermissionChoice.allCases {
            XCTAssertFalse(CodexCommand.sandboxArguments(choice).contains("danger-full-access"))
            XCTAssertFalse(CodexCommand.sandboxArguments(choice).contains("--approve-for-me"))
        }
    }

    func testArgumentsUseTheDocumentedFlagsAndReadThePromptFromStdin() {
        let fresh = CodexCommand.arguments(workspace: "/w", permission: .auto, addDirs: ["/b"], instructions: "say \"hi\"\n", wispBinary: "/opt/wisp/venv/bin/wisp")
        XCTAssertEqual(Array(fresh.prefix(5)), ["exec", "--json", "--skip-git-repo-check", "-C", "/w"])
        XCTAssertFalse(fresh.contains("--approve-for-me"))
        XCTAssertTrue(fresh.contains("workspace-write"))
        XCTAssertEqual(fresh.last, "-")
        XCTAssertTrue(fresh.contains("developer_instructions=\"say \\\"hi\\\"\\n\""))
        XCTAssertEqual(Array(fresh[fresh.firstIndex(of: "--add-dir")!...].prefix(2)), ["--add-dir", "/b"])
        let resumed = CodexCommand.arguments(workspace: "/w", permission: .bypass, wispBinary: "/opt/wisp/venv/bin/wisp", resume: Self.thread)
        XCTAssertEqual(Array(resumed.suffix(3)), ["resume", Self.thread, "-"])
        XCTAssertFalse(resumed.contains("--approve-for-me"))
    }

    private func tree() throws -> (root: URL, home: URL, project: URL, wisp: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-ws-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let project = home.appendingPathComponent("project")
        let wisp = home.appendingPathComponent("Wisp")
        for dir in [project, wisp] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return (root, home, project, wisp)
    }

    func testWorkspaceIsNeverHomeOrAParentOfHome() throws {
        let t = try tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let wisp = t.wisp.resolvingSymlinksInPath().path
        func pick(_ preferred: String?) -> String? {
            CodexCommand.workspace(preferred: preferred, home: t.home.path, wispDir: t.wisp.path)
        }
        XCTAssertEqual(pick(t.home.path), wisp)
        XCTAssertEqual(pick(t.root.path), wisp)
        XCTAssertEqual(pick("/"), wisp)
        XCTAssertEqual(pick(nil), wisp)
        XCTAssertEqual(pick(""), wisp)
        XCTAssertEqual(pick("   "), wisp)
        XCTAssertEqual(pick(t.home.appendingPathComponent("missing").path), wisp)
        XCTAssertEqual(pick(t.project.path), t.project.resolvingSymlinksInPath().path)
    }

    func testWorkspaceResolvesSymlinksToHome() throws {
        let t = try tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let link = t.root.appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.home)
        XCTAssertNil(CodexCommand.safeDirectory(link.path, home: t.home.path))
        XCTAssertEqual(
            CodexCommand.workspace(preferred: link.path, home: t.home.path, wispDir: t.wisp.path),
            t.wisp.resolvingSymlinksInPath().path)
    }

    func testNoSafeWorkspaceMeansNoCodexTurn() throws {
        let t = try tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let wispIsHome = t.root.appendingPathComponent("wisp-link")
        try FileManager.default.createSymbolicLink(at: wispIsHome, withDestinationURL: t.home)
        XCTAssertNil(CodexCommand.workspace(preferred: t.home.path, home: t.home.path, wispDir: wispIsHome.path))
        XCTAssertNil(CodexCommand.workspace(preferred: nil, home: t.home.path, wispDir: t.root.path))
        XCTAssertNil(CodexCommand.workspace(preferred: "", home: t.home.path, wispDir: ""))
    }

    func testExtraDirectoriesAreResolvedAndNeverHomeOrAbove() throws {
        let t = try tree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let brainLink = t.root.appendingPathComponent("brain-link")
        try FileManager.default.createSymbolicLink(at: brainLink, withDestinationURL: t.home)
        let elsewhere = t.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let realLink = t.root.appendingPathComponent("real-link")
        try FileManager.default.createSymbolicLink(at: realLink, withDestinationURL: elsewhere)
        let wisp = t.wisp.resolvingSymlinksInPath().path
        func extras(_ candidates: [String]) -> [String] {
            CodexCommand.extraDirectories(workspace: t.project.path, candidates: candidates, home: t.home.path)
        }
        XCTAssertEqual(extras([t.wisp.path, brainLink.path]), [wisp])
        XCTAssertEqual(extras([t.wisp.path, t.root.path, "/"]), [wisp])
        XCTAssertEqual(extras([t.wisp.path, realLink.path]), [wisp, elsewhere.resolvingSymlinksInPath().path])
        XCTAssertEqual(extras([t.project.path]), [])
    }

    func testActiveEngineComesFromModelosTomlAtTheTopLevelOnly() {
        XCTAssertEqual(EngineChoice.parseActive("# x\nativo = \"codex\"  # which\n"), "codex")
        XCTAssertNil(EngineChoice.parseActive("[local]\nativo = \"codex\"\n"))
        XCTAssertNil(EngineChoice.parseActive("ativo = \n"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-m-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(EngineChoice.active(wispDir: dir), .claude)
        try? "ativo = \"codex\"\n".write(to: EngineChoice.modelosURL(wispDir: dir), atomically: true, encoding: .utf8)
        XCTAssertEqual(EngineChoice.active(wispDir: dir), .codex)
        try? "ativo = \"unknown\"\n".write(to: EngineChoice.modelosURL(wispDir: dir), atomically: true, encoding: .utf8)
        XCTAssertEqual(EngineChoice.active(wispDir: dir), .claude)
    }

    private func fakeCodex(in dir: URL, fixture: String) throws -> URL {
        let script = dir.appendingPathComponent("codex")
        let body = """
        #!/bin/sh
        echo "$@" >> "\(dir.path)/argv"
        cat > /dev/null
        cat <<'EOF'
        \(try contract(fixture))EOF
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func collectResults(_ session: CodexSession, count: Int) async -> [SessionEvent] {
        let stream = session.events
        return await withTaskGroup(of: [SessionEvent].self) { group in
            group.addTask {
                var seen: [SessionEvent] = []
                var results = 0
                for await event in stream {
                    seen.append(event)
                    if case .claude(.result) = event { results += 1 }
                    if results == count { break }
                }
                return seen
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    func testSessionRunsOneProcessPerTurnAndResumesTheThread() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-cx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = CodexSession(
            executable: try fakeCodex(in: dir, fixture: "codex-exec-stream-from-docs.jsonl"), cwd: dir, resume: nil,
            permission: .ask, instructions: "be brief", wispBinary: "/opt/wisp/venv/bin/wisp")
        try await session.start()
        try await session.send("one")
        try await session.send("two")
        let events = await collectResults(session, count: 2)
        XCTAssertEqual(events.filter { if case .claude(.result) = $0 { true } else { false } }.count, 2)
        XCTAssertTrue(events.contains(.claude(.engineSession(engine: "codex", id: Self.thread))))
        let argv = try String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(argv.count, 2)
        XCTAssertFalse(argv[0].contains("resume"))
        XCTAssertTrue(argv[1].contains("resume \(Self.thread) -"))
        XCTAssertTrue(argv[0].contains("--sandbox read-only"))
        for override in try overridesContract() { XCTAssertTrue(argv[0].contains(override), override) }
        XCTAssertLessThan(try XCTUnwrap(argv[1].range(of: "enabled=true")).lowerBound, try XCTUnwrap(argv[1].range(of: "resume \(Self.thread)")).lowerBound)
        let routes = session.routesApprovals
        XCTAssertFalse(routes)
        await session.stop()
    }

    func testSessionThatExitsZeroWithoutCompletionReportsAnError() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-cx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = CodexSession(
            executable: try fakeCodex(in: dir, fixture: "codex-exec-incomplete-from-docs.jsonl"), cwd: dir, resume: nil, permission: .ask, wispBinary: "/opt/wisp/venv/bin/wisp")
        try await session.start()
        try await session.send("oi")
        let events = await collectResults(session, count: 1)
        guard case .claude(.result(_, let text, true, _))? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(text, CodexEventDecoder.incomplete)
        await session.stop()
    }

    func testSessionThatCannotResumeReportsALostSession() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-cx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("codex")
        try "#!/bin/sh\ncat >/dev/null\necho 'thread not found' >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let session = CodexSession(executable: script, cwd: dir, resume: Self.thread, permission: .auto, wispBinary: "/opt/wisp/venv/bin/wisp")
        try await session.start()
        try await session.send("oi")
        let events = await collectResults(session, count: 1)
        guard case .claude(.result(_, let text, true, _))? = events.last else { return XCTFail("\(events)") }
        XCTAssertTrue(ConversationTranscript.isLostSession(text))
        await session.stop()
    }

    private func overridesContract() throws -> [String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cli/tests/fixtures/contract/codex-mcp-overrides.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["overrides"] as? [String])
    }

    func testTheWholeEmailServerIsPassedAsOverridesOnEveryLaunchAndMatchesTheContract() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cli/tests/fixtures/contract/codex-mcp-overrides.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let binary = try XCTUnwrap(object["wisp_bin"] as? String)
        XCTAssertEqual(CodexCommand.mcpOverrides(wispBinary: binary), try overridesContract())
        for permission in [PermissionChoice.ask, .auto, .bypass] {
            for resume in [nil, Self.thread] {
                let args = CodexCommand.arguments(workspace: "/w", permission: permission, wispBinary: binary, resume: resume)
                for override in try overridesContract() {
                    let index = try XCTUnwrap(args.firstIndex(of: override), override)
                    XCTAssertEqual(args[index - 1], "-c")
                }
                let last = try XCTUnwrap(overridesContract().last)
                if resume != nil { XCTAssertLessThan(try XCTUnwrap(args.firstIndex(of: last)), try XCTUnwrap(args.firstIndex(of: "resume"))) }
            }
        }
    }

    func testAUserOwnedBrainServerGetsNoOverrideButTheEmailServerAlwaysDoes() {
        let all = CodexCommand.mcpOverrides(wispBinary: "/opt/wisp/venv/bin/wisp")
        let skipped = CodexCommand.mcpOverrides(wispBinary: "/opt/wisp/venv/bin/wisp", ownedByUser: [CodexCommand.brainServer])
        XCTAssertTrue(all.contains { $0.hasPrefix("mcp_servers.wisp-brain.") })
        XCTAssertFalse(skipped.contains { $0.hasPrefix("mcp_servers.wisp-brain.") })
        XCTAssertEqual(skipped, all.filter { $0.hasPrefix("mcp_servers.wisp-email.") })
        let args = CodexCommand.arguments(workspace: "/w", permission: .ask, wispBinary: "/opt/wisp/venv/bin/wisp", ownedByUser: [CodexCommand.brainServer])
        XCTAssertFalse(args.contains { $0.hasPrefix("mcp_servers.wisp-brain.") })
        XCTAssertTrue(args.contains { $0.hasPrefix("mcp_servers.wisp-email.") })
    }

    func testASessionWithoutTheWispBinaryNeverRunsCodex() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-cx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = CodexSession(
            executable: try fakeCodex(in: dir, fixture: "codex-exec-stream-from-docs.jsonl"), cwd: dir, resume: nil, permission: .ask)
        try await session.start()
        try await session.send("oi")
        var seen: SessionEvent?
        for await event in session.events {
            seen = event
            break
        }
        XCTAssertEqual(seen, .exited(code: -1, stderrTail: CodexSession.noWispBinary))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("argv").path))
        await session.stop()
    }

    func testSessionRefusesAnAnswerWithNoPendingBrokerRequest() async throws {
        let session = CodexSession(executable: URL(fileURLWithPath: "/usr/bin/true"), cwd: FileManager.default.temporaryDirectory, resume: nil, permission: .ask, wispBinary: "/opt/wisp/venv/bin/wisp")
        let request = PermissionRequest(id: "r", toolName: "Bash", summary: "x", detail: "x")
        do {
            try await session.respond(to: request, .allow)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentError, .approvalsNotRouted)
        }
    }

    func testExitedMessageNamesTheActiveEngine() {
        var state = ConversationState()
        state.engineName = "codex"
        ConversationReducer.reduce(&state, .exited(code: -1, stderrTail: "x"), statusPrefix: nil)
        XCTAssertEqual(state.phase, .failed("codex encerrou (código -1): x"))
    }
}
