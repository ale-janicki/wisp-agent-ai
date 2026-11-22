import XCTest
@testable import WispCore

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [PermissionRequest] = []
    private var cancelled: [String] = []

    func add(_ request: PermissionRequest) { lock.lock(); requests.append(request); lock.unlock() }
    func cancel(_ id: String) { lock.lock(); cancelled.append(id); lock.unlock() }
    var allRequests: [PermissionRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    var allCancelled: [String] { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class ApprovalBrokerTests: XCTestCase {
    private func contract() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cli/tests/fixtures/contract/approval-broker.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func requestLine() throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: try contract()["request"]!, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    private func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); throw BrokerError.socket(String(cString: strerror(errno))) }
        return fd
    }

    private func put(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress!, $0.count) }
    }

    private func reply(_ fd: Int32, within seconds: Double = 5) -> [String: String]? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(seconds)
        while !data.contains(0x0A) {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(max(deadline.timeIntervalSinceNow, 0) * 1000)) > 0 else { return nil }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            data.append(contentsOf: chunk[0..<n])
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    private func broker(_ seen: Seen, validity: TimeInterval = 5) throws -> ApprovalBroker {
        try ApprovalBroker(validity: validity, onRequest: { seen.add($0) }, onCancel: { seen.cancel($0) })
    }

    func testTheSocketLivesInAPrivateFolderAndGoesAwayOnStop() throws {
        let broker = try broker(Seen())
        let folder = URL(fileURLWithPath: broker.path).deletingLastPathComponent().path
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        let socketMode = try FileManager.default.attributesOfItem(atPath: broker.path)[.posixPermissions] as? Int
        XCTAssertEqual(folderMode, 0o700)
        XCTAssertEqual(socketMode, 0o600)
        XCTAssertLessThanOrEqual(broker.path.utf8.count, 103)
        broker.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
    }

    func testTheRequestBecomesTheNormalCardAndOnlyTheHostAnswerAllows() async throws {
        let seen = Seen()
        let broker = try broker(seen)
        defer { broker.stop() }
        let fd = try connect(broker.path)
        defer { close(fd) }
        put(fd, try requestLine())
        await waitFor { !seen.allRequests.isEmpty }
        let card = try XCTUnwrap(seen.allRequests.first)
        XCTAssertEqual(card.toolName, try XCTUnwrap(contract()["tool"] as? String))
        XCTAssertEqual(card.engine, "codex")
        XCTAssertEqual(card.asker, "Codex")
        XCTAssertEqual(card.summary, "enviar um e-mail")
        XCTAssertFalse(card.canPersist)
        XCTAssertTrue(card.requiresExpansion)
        for part in ["ana@exemplo.com", "bia@exemplo.com", "Oi", "Olá, tudo bem?"] { XCTAssertTrue(card.detail.contains(part), part) }
        XCTAssertFalse(broker.answer(id: "unknown", allow: true))
        XCTAssertEqual(reply(fd, within: 0.2) ?? [:], [:], "nothing is answered before the user clicks")
        XCTAssertTrue(broker.answer(id: card.id, allow: true))
        XCTAssertFalse(broker.answer(id: card.id, allow: false), "one answer per request")
    }

    func testAllowIsAnsweredToTheClient() async throws {
        let seen = Seen()
        let broker = try broker(seen)
        defer { broker.stop() }
        let fd = try connect(broker.path)
        defer { close(fd) }
        put(fd, try requestLine())
        await waitFor { !seen.allRequests.isEmpty }
        XCTAssertTrue(broker.answer(id: seen.allRequests[0].id, allow: true))
        XCTAssertEqual(reply(fd), try XCTUnwrap(contract()["allow"] as? [String: String]))
    }

    func testDenyIsAnsweredWithTheTextTheModelReads() async throws {
        let seen = Seen()
        let broker = try broker(seen)
        defer { broker.stop() }
        let fd = try connect(broker.path)
        defer { close(fd) }
        put(fd, try requestLine())
        await waitFor { !seen.allRequests.isEmpty }
        XCTAssertTrue(broker.answer(id: seen.allRequests[0].id, allow: false))
        XCTAssertEqual(reply(fd), ["decision": "deny", "message": ApprovalBroker.denied])
    }

    func testNoAnswerInTimeDeniesAndWithdrawsTheCard() async throws {
        let seen = Seen()
        let broker = try broker(seen, validity: 0.3)
        defer { broker.stop() }
        let fd = try connect(broker.path)
        defer { close(fd) }
        put(fd, try requestLine())
        XCTAssertEqual(reply(fd), ["decision": "deny", "message": ApprovalBroker.expired])
        XCTAssertEqual(seen.allCancelled, seen.allRequests.map(\.id))
        XCTAssertFalse(seen.allCancelled.isEmpty)
    }

    func testAClientThatDisappearsWithdrawsTheCard() async throws {
        let seen = Seen()
        let broker = try broker(seen)
        defer { broker.stop() }
        let fd = try connect(broker.path)
        put(fd, try requestLine())
        await waitFor { !seen.allRequests.isEmpty }
        close(fd)
        await waitFor { !seen.allCancelled.isEmpty }
        XCTAssertEqual(seen.allCancelled, seen.allRequests.map(\.id))
        XCTAssertFalse(broker.answer(id: seen.allRequests[0].id, allow: true))
    }

    func testTheClientHasNoApproveVerbAndNothingMalformedReachesTheHost() throws {
        let seen = Seen()
        let broker = try broker(seen)
        defer { broker.stop() }
        let input = #""input":{"to":["a@b.c"],"subject":"s","body":"b"}"#
        let bad = [
            "not json", "", "[]", #"{"op":"approve","tool":"email_send",\#(input)}"#, #"{"op":"allow"}"#,
            #"{"decision":"allow"}"#, #"{"approve":true}"#, #"{"op":"answer","tool":"email_send",\#(input)}"#,
            #"{"op":"request","tool":"Bash",\#(input)}"#, #"{"op":"request","tool":"email_send","input":"x"}"#,
            #"{"op":"request","tool":"email_send"}"#,
        ]
        for line in bad {
            let fd = try connect(broker.path)
            put(fd, Data((line + "\n").utf8))
            XCTAssertEqual(reply(fd), ["decision": "deny", "message": ApprovalBroker.malformed], line)
            close(fd)
        }
        XCTAssertTrue(seen.allRequests.isEmpty)
    }

    func testBytesAfterTheRequestNeverTurnIntoAnAllow() async throws {
        let seen = Seen()
        let broker = try broker(seen)
        defer { broker.stop() }
        let fd = try connect(broker.path)
        defer { close(fd) }
        put(fd, try requestLine() + Data(#"{"decision":"allow"}"#.utf8) + Data([0x0A]))
        XCTAssertNil(reply(fd, within: 1))
        XCTAssertTrue(seen.allRequests.isEmpty)
    }

    func testStopWithdrawsEveryPendingCard() async throws {
        let seen = Seen()
        let broker = try broker(seen)
        let fd = try connect(broker.path)
        defer { close(fd) }
        put(fd, try requestLine())
        await waitFor { !seen.allRequests.isEmpty }
        broker.stop()
        await waitFor { !seen.allCancelled.isEmpty }
        XCTAssertEqual(seen.allCancelled, seen.allRequests.map(\.id))
        XCTAssertNil(reply(fd, within: 1).flatMap { $0["decision"] == "allow" ? $0 : nil })
    }

    func testTheCodexProcessEnvironmentCarriesTheSameWispBinaryAsTheEmailOverrides() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-cx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("codex")
        let body = """
        #!/bin/sh
        cat > /dev/null
        echo "$WISP_BIN" > "\(dir.path)/bin"
        echo '{"type":"turn.completed"}'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let session = CodexSession(
            executable: script, cwd: dir, resume: nil, permission: .ask, environmentOverrides: ["WISP_BIN": "/elsewhere/wisp"],
            wispBinary: "/opt/wisp/venv/bin/wisp")
        try await session.start()
        try await session.send("oi")
        let file = dir.appendingPathComponent("bin")
        await waitFor { FileManager.default.fileExists(atPath: file.path) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "/opt/wisp/venv/bin/wisp\n")
        XCTAssertEqual(CodexCommand.environment(executable: script, wispBinary: "/opt/wisp/venv/bin/wisp")["WISP_BIN"], "/opt/wisp/venv/bin/wisp")
        XCTAssertTrue(CodexCommand.mcpOverrides(wispBinary: "/opt/wisp/venv/bin/wisp")[0].contains("/opt/wisp/venv/bin/wisp"))
        await session.stop()
    }

    func testTheSessionHandsTheSocketToCodexAndRoutesItsRequestToTheCardAndTheAnswerBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-cx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("codex")
        let body = """
        #!/bin/sh
        cat > /dev/null
        echo "$WISP_APPROVAL_SOCKET" > "\(dir.path)/socket"
        i=0
        while [ ! -f "\(dir.path)/go" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
        echo '{"type":"turn.completed"}'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let session = CodexSession(executable: script, cwd: dir, resume: nil, permission: .ask, wispBinary: "/opt/wisp/venv/bin/wisp")
        try await session.start()
        try await session.send("oi")
        let socketFile = dir.appendingPathComponent("socket")
        await waitFor { FileManager.default.fileExists(atPath: socketFile.path) }
        let path = try String(contentsOf: socketFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(path.hasSuffix("/b"))
        let fd = try connect(path)
        defer { close(fd) }
        put(fd, try requestLine())
        var card: PermissionRequest?
        for await event in session.events {
            if case .claude(.permissionRequest(let request)) = event { card = request; break }
        }
        let request = try XCTUnwrap(card)
        XCTAssertTrue(request.detail.contains("ana@exemplo.com"))
        try await session.respond(to: request, .allow)
        XCTAssertEqual(reply(fd), ["decision": "allow"])
        do {
            try await session.respond(to: request, .allow)
            XCTFail("a request is answered once")
        } catch {
            XCTAssertEqual(error as? AgentError, .approvalsNotRouted)
        }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("go").path, contents: Data())
        await session.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
    }

    func testTheConversationShowsABrokerRequestAsTheApprovalCardAndDropsItWhenWithdrawn() throws {
        let request = try XCTUnwrap(ApprovalBroker.permissionRequest(requestLine()))
        var state = ConversationState()
        state.engineName = "codex"
        ConversationReducer.reduce(&state, .claude(.permissionRequest(request)), statusPrefix: nil)
        XCTAssertEqual(state.approvals.map(\.id), [request.id])
        ConversationReducer.reduce(&state, .claude(.permissionCancelled(id: request.id)), statusPrefix: nil)
        XCTAssertTrue(state.approvals.isEmpty)
    }

    func testTheSameToolUnderClaudeKeepsTheClaudeWording() throws {
        let request = try XCTUnwrap(PermissionRequest(
            requestId: "r", request: ["subtype": "can_use_tool", "tool_name": "mcp__wisp-email__email_send", "input": ["to": ["a@b.c"]]]))
        XCTAssertEqual(request.asker, "Claude")
        XCTAssertTrue(request.summary.hasPrefix("usar mcp__wisp-email__email_send"))
    }

    func testDroppingTheBrokerWithoutStopRemovesTheFolder() async throws {
        var broker: ApprovalBroker? = try broker(Seen())
        let folder = URL(fileURLWithPath: try XCTUnwrap(broker).path).deletingLastPathComponent().path
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder))
        broker = nil
        await waitFor { !FileManager.default.fileExists(atPath: folder) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
    }

    func testDroppingTheSessionWithoutStopRemovesTheFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-cx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var session: CodexSession? = CodexSession(
            executable: URL(fileURLWithPath: "/usr/bin/true"), cwd: dir, resume: nil, permission: .ask, wispBinary: "/opt/wisp/venv/bin/wisp")
        try await session?.start()
        let socket = await session?.approvalSocketPath
        let path = try XCTUnwrap(socket)
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder))
        session = nil
        await waitFor { !FileManager.default.fileExists(atPath: folder) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
    }

    func testStopRacingWithManyPendingRequestsNeverTouchesAClosedDescriptor() async throws {
        for _ in 0..<5 {
            let seen = Seen()
            let broker = try broker(seen)
            var clients: [Int32] = []
            for _ in 0..<12 {
                let fd = try connect(broker.path)
                put(fd, try requestLine())
                clients.append(fd)
            }
            await waitFor { seen.allRequests.count == 12 }
            let stopper = Task.detached { broker.stop() }
            for request in seen.allRequests { broker.answer(id: request.id, allow: true) }
            await stopper.value
            try await Task.sleep(for: .milliseconds(100))
            clients.forEach { close($0) }
        }
    }

    func testDeadSessionFoldersAreSweptAndLiveOnesAreNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-sweep-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ name: String, files: [String] = ["b"]) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in files { FileManager.default.createFile(atPath: url.appendingPathComponent(file).path, contents: Data()) }
            return url
        }
        let dead = try make("wisp-999999-abcdef01")
        let live = try make("wisp-\(getpid())-abcdef02")
        let foreign = try make("wisp-999998-abcdef03", files: ["notes.txt"])
        let other = try make("wisp-notes")
        BrokerCore.sweepDead(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        for kept in [live, foreign, other] { XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent) }
    }

    func testABrokerThatCannotStartIsReportedByTheSession() async throws {
        let deep = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(repeating: "d", count: 60)).appendingPathComponent(String(repeating: "e", count: 60))
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: deep.deletingLastPathComponent()) }
        let session = CodexSession(
            executable: URL(fileURLWithPath: "/usr/bin/true"), cwd: FileManager.default.homeDirectoryForCurrentUser, resume: nil,
            permission: .ask, approvalDirectory: deep, wispBinary: "/opt/wisp/venv/bin/wisp")
        try await session.start()
        let problem = await session.approvalChannelProblem
        let path = await session.approvalSocketPath
        XCTAssertNotNil(problem)
        XCTAssertNil(path)
        await session.stop()
    }

    func testReadinessRequiresTheSendGateCheckOfTheWispCLI() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-rd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func script(_ name: String, _ body: String) throws -> String {
            let url = dir.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        XCTAssertTrue(CodexReadiness.sendGate(wispBinary: try script("ok", #"echo '{"ready": true, "problem": null}'"#), environment: [:]))
        XCTAssertFalse(CodexReadiness.sendGate(wispBinary: try script("stale", #"echo '{"ready": false, "problem": "x"}'; exit 1"#), environment: [:]))
        XCTAssertFalse(CodexReadiness.sendGate(wispBinary: try script("liar", #"echo '{"ready": true}'; exit 1"#), environment: [:]))
        XCTAssertFalse(CodexReadiness.sendGate(wispBinary: try script("junk", "echo hi"), environment: [:]))
        XCTAssertFalse(CodexReadiness.sendGate(wispBinary: dir.appendingPathComponent("missing").path, environment: [:]))
        XCTAssertFalse(CodexReadiness.sendGate(wispBinary: nil, environment: [:]))
        let probe = dir.appendingPathComponent("probe").path
        let seeing = try script("env", "echo \"$WISP_PROBE|$PATH\" > \(probe); echo '{\"ready\": true}'")
        let launchEnvironment = CodexCommand.environment(executable: URL(fileURLWithPath: "/usr/bin/true"), overrides: ["WISP_PROBE": "same"])
        XCTAssertTrue(CodexReadiness.sendGate(wispBinary: seeing, environment: launchEnvironment))
        XCTAssertEqual(try String(contentsOfFile: probe, encoding: .utf8), "same|\(try XCTUnwrap(launchEnvironment["PATH"]))\n")
        XCTAssertFalse(CodexReadiness(installed: true, loggedIn: true, sendGateOK: false).ready)
        XCTAssertTrue(CodexReadiness(installed: true, loggedIn: true).ready)
        XCTAssertTrue(CodexReadiness(installed: true, loggedIn: true, sendGateOK: false).note().contains("wisp harness sync"))
    }

    // MARK: Claude tickets, peer check and the single card

    private func ticketMail() throws -> [String: Any] {
        try XCTUnwrap(XCTUnwrap(contract()["ticket"] as? [String: Any])["input"] as? [String: Any])
    }

    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private func ask(_ mail: [String: Any]) throws -> Data {
        Data((try json(["op": "request", "tool": "email_send", "input": mail]) + "\n").utf8)
    }

    private func answer(_ broker: ApprovalBroker, _ mail: [String: Any]) throws -> [String: String]? {
        let fd = try connect(broker.path)
        defer { close(fd) }
        put(fd, try ask(mail))
        return reply(fd)
    }

    private func ticketBroker(validity: TimeInterval = 120, uid: uid_t = getuid()) throws -> ApprovalBroker {
        try ApprovalBroker(live: false, hostUID: uid, ticketValidity: validity)
    }

    func testTheHashMatchesTheContractVectorAndAMissingCcIsEmpty() throws {
        let ticket = try XCTUnwrap(contract()["ticket"] as? [String: Any])
        let expected = try XCTUnwrap(ticket["sha256"] as? String)
        XCTAssertEqual(ApprovalBroker.fingerprint(try ticketMail()), expected)
        XCTAssertEqual(ApprovalBroker.fingerprint(try XCTUnwrap(ticket["same_without_cc"] as? [String: Any])), expected)
        var bad = try ticketMail()
        bad["to"] = "ana@exemplo.com"
        XCTAssertNil(ApprovalBroker.fingerprint(bad))
        bad = try ticketMail()
        bad["subject"] = 1
        XCTAssertNil(ApprovalBroker.fingerprint(bad))
    }

    func testAClaudeTicketIsConsumedOnceAndTheSecondSendIsRefused() throws {
        let broker = try ticketBroker()
        defer { broker.stop() }
        XCTAssertTrue(broker.authorize(inputJSON: try json(try ticketMail())))
        XCTAssertEqual(try answer(broker, try ticketMail()), try XCTUnwrap(contract()["allow"] as? [String: String]))
        XCTAssertEqual(try answer(broker, try ticketMail()), ["decision": "deny", "message": ApprovalBroker.noTicket])
    }

    func testNoTicketMeansNoSend() throws {
        let broker = try ticketBroker()
        defer { broker.stop() }
        XCTAssertEqual(try answer(broker, try ticketMail()), ["decision": "deny", "message": ApprovalBroker.noTicket])
    }

    func testATicketForDifferentContentIsRefusedAndStaysValidForTheRightMail() throws {
        let broker = try ticketBroker()
        defer { broker.stop() }
        XCTAssertTrue(broker.authorize(inputJSON: try json(try ticketMail())))
        let mail = try ticketMail()
        let to = try XCTUnwrap(mail["to"] as? [String])
        let changes: [[String: Any]] = [
            ["to": ["x@exemplo.com"]], ["cc": ["x@exemplo.com"]], ["subject": "Outro"], ["body": "outro corpo"],
            ["to": Array(to.reversed())], ["to": to + ["x@exemplo.com"]],
        ]
        for change in changes {
            XCTAssertEqual(try answer(broker, mail.merging(change) { $1 }), ["decision": "deny", "message": ApprovalBroker.noTicket], "\(change)")
        }
        XCTAssertEqual(try answer(broker, mail), try XCTUnwrap(contract()["allow"] as? [String: String]))
    }

    func testAnExpiredTicketIsRefused() async throws {
        let broker = try ticketBroker(validity: 0.1)
        defer { broker.stop() }
        XCTAssertTrue(broker.authorize(inputJSON: try json(try ticketMail())))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try answer(broker, try ticketMail()), ["decision": "deny", "message": ApprovalBroker.noTicket])
    }

    func testNoTicketIsMintedForAMalformedInput() throws {
        let broker = try ticketBroker()
        defer { broker.stop() }
        for text in ["not json", "{}", #"{"to":"a@b.c","subject":"s","body":"b"}"#, #"{"to":["a@b.c"],"subject":1,"body":"b"}"#] {
            XCTAssertFalse(broker.authorize(inputJSON: text), text)
        }
    }

    func testTheSocketHasNoVerbThatMintsATicket() throws {
        let broker = try ticketBroker()
        defer { broker.stop() }
        for op in ["authorize", "mint", "ticket", "allow", "approve"] {
            let fd = try connect(broker.path)
            put(fd, Data((try json(["op": op, "tool": "email_send", "input": try ticketMail()]) + "\n").utf8))
            XCTAssertEqual(reply(fd), ["decision": "deny", "message": ApprovalBroker.malformed], op)
            close(fd)
        }
        XCTAssertEqual(try answer(broker, try ticketMail()), ["decision": "deny", "message": ApprovalBroker.noTicket])
    }

    func testAPeerWithAnotherUidIsDroppedWithoutBeingReadOrAsked() throws {
        let seen = Seen()
        let broker = try ApprovalBroker(hostUID: getuid() &+ 1, onRequest: { seen.add($0) }, onCancel: { seen.cancel($0) })
        defer { broker.stop() }
        XCTAssertTrue(broker.authorize(inputJSON: try json(try ticketMail())))
        let fd = try connect(broker.path)
        defer { close(fd) }
        put(fd, try ask(try ticketMail()))
        XCTAssertNil(reply(fd, within: 1))
        XCTAssertTrue(seen.allRequests.isEmpty)
    }

    func testOnlyOneCardIsOpenAtATimeAndTheExtraRequestIsRefused() async throws {
        let seen = Seen()
        let broker = try broker(seen)
        defer { broker.stop() }
        let first = try connect(broker.path)
        defer { close(first) }
        put(first, try ask(try ticketMail()))
        await waitFor { !seen.allRequests.isEmpty }
        for index in 0..<3 {
            let mail = try ticketMail().merging(["subject": "outro \(index)"]) { $1 }
            XCTAssertEqual(try answer(broker, mail), ["decision": "deny", "message": ApprovalBroker.busy])
        }
        XCTAssertEqual(seen.allRequests.count, 1)
        XCTAssertTrue(broker.answer(id: seen.allRequests[0].id, allow: true))
        XCTAssertEqual(reply(first), try XCTUnwrap(contract()["allow"] as? [String: String]))
        let again = try connect(broker.path)
        defer { close(again) }
        put(again, try ask(try ticketMail().merging(["subject": "depois"]) { $1 }))
        await waitFor { seen.allRequests.count == 2 }
        XCTAssertEqual(seen.allRequests.count, 2, "a new card opens once the previous one is answered")
    }

    private func claudeScript(in dir: URL, mail: [String: Any], sent: [String: Any]) throws -> URL {
        let request = try json([
            "type": "control_request", "request_id": "r1",
            "request": ["subtype": "can_use_tool", "tool_name": "mcp__wisp-email__email_send", "tool_use_id": "t1", "input": mail],
        ])
        let ask = try json(["op": "request", "tool": "email_send", "input": sent])
        let script = dir.appendingPathComponent("claude")
        let body = """
        #!/bin/sh
        read -r user
        printf '%s\\n' '\(request)'
        read -r answer
        printf '%s\n' '\(ask)' | /usr/bin/nc -U -w 5 "$WISP_APPROVAL_SOCKET" > "\(dir.path)/out1"
        printf '%s\n' '\(ask)' | /usr/bin/nc -U -w 5 "$WISP_APPROVAL_SOCKET" > "\(dir.path)/out2"
        touch "\(dir.path)/done"
        cat > /dev/null
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func runClaudeTurn(decision: PermissionDecision, sent: [String: Any]) async throws -> (String, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-cl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try claudeScript(in: dir, mail: try ticketMail(), sent: sent)
        let session = AgentSession(executable: script, cwd: dir, model: nil, resume: nil)
        try await session.start()
        try await session.send("oi")
        var card: PermissionRequest?
        for await event in session.events {
            if case .claude(.permissionRequest(let request)) = event { card = request; break }
        }
        try await session.respond(to: try XCTUnwrap(card), decision)
        await waitFor { FileManager.default.fileExists(atPath: dir.appendingPathComponent("done").path) }
        let first = (try? String(contentsOf: dir.appendingPathComponent("out1"), encoding: .utf8)) ?? ""
        let second = (try? String(contentsOf: dir.appendingPathComponent("out2"), encoding: .utf8)) ?? ""
        await session.stop()
        return (first, second)
    }

    func testAClaudeTurnSendsOnlyAfterTheUserAllowedThatExactMailAndOnlyOnce() async throws {
        let (first, second) = try await runClaudeTurn(decision: .allow, sent: try ticketMail())
        XCTAssertEqual(first.trimmingCharacters(in: .whitespacesAndNewlines), #"{"decision":"allow"}"#)
        XCTAssertTrue(second.contains("deny") && second.contains("nada foi enviado"), second)
    }

    func testAClaudeTurnTheUserDeniedOrWithOtherContentGetsNoTicket() async throws {
        let denied = try await runClaudeTurn(decision: .deny, sent: try ticketMail())
        XCTAssertTrue(denied.0.contains("deny") && denied.0.contains("nada foi enviado"), denied.0)
        let swapped = try await runClaudeTurn(decision: .allow, sent: try ticketMail().merging(["body": "trocado depois do clique"]) { $1 })
        XCTAssertTrue(swapped.0.contains("deny") && swapped.0.contains("nada foi enviado"), swapped.0)
    }
}

final class CodexProjectConfigTests: XCTestCase {
    private func script(in dir: URL, _ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-pc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testTheProjectProblemIsTheFileTheCLINamesAndAnythingUnusableIsRefused() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let named = try script(in: dir, "named", #"echo '{"ready": false, "problem": null, "project": "o arquivo /w/.codex/config.toml define o servidor wisp-email do Codex"}'; exit 1"#)
        let clean = try script(in: dir, "clean", #"echo '{"ready": true, "problem": null, "project": null}'"#)
        let gateOnly = try script(in: dir, "gate", #"echo '{"ready": false, "problem": "x", "project": null}'; exit 1"#)
        XCTAssertEqual(
            CodexReadiness.projectProblem(wispBinary: named, environment: [:], workspace: "/w"),
            "o arquivo /w/.codex/config.toml define o servidor wisp-email do Codex")
        XCTAssertNil(CodexReadiness.projectProblem(wispBinary: clean, environment: [:], workspace: "/w"))
        XCTAssertNil(CodexReadiness.projectProblem(wispBinary: gateOnly, environment: [:], workspace: "/w"))
        let junk = try script(in: dir, "junk", "echo hi")
        for binary in [junk, dir.appendingPathComponent("missing").path, nil, ""] as [String?] {
            XCTAssertEqual(
                CodexReadiness.projectProblem(wispBinary: binary, environment: [:], workspace: "/w"), CodexReadiness.projectUnchecked)
        }
    }

    func testOnePreflightRunReturnsTheProblemAndTheServersTheUserOwns() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = dir.appendingPathComponent("runs").path
        let binary = try script(in: dir, "wisp", #"echo run >> \#(count); echo '{"ready": true, "problem": null, "project": null, "owned": ["wisp-brain"]}'"#)
        let verdict = CodexReadiness.preflight(wispBinary: binary, environment: [:], workspace: "/w")
        XCTAssertEqual(verdict, CodexPreflight(problem: nil, ownedByUser: ["wisp-brain"]))
        XCTAssertEqual(try String(contentsOfFile: count, encoding: .utf8), "run\n")
        let broken = try script(in: dir, "broken", "echo hi")
        XCTAssertEqual(CodexReadiness.preflight(wispBinary: broken, environment: [:], workspace: "/w"), CodexPreflight(problem: CodexReadiness.projectUnchecked))
    }

    func testTheCLIReceivesTheWorkspaceAndReadinessCarriesTheProblemInItsNote() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = dir.appendingPathComponent("args").path
        let binary = try script(in: dir, "wisp", "echo \"$@\" > \(seen); echo '{\"ready\": true, \"project\": null}'")
        XCTAssertNil(CodexReadiness.projectProblem(wispBinary: binary, environment: [:], workspace: "/some/work"))
        XCTAssertEqual(try String(contentsOfFile: seen, encoding: .utf8), "codex check --workspace /some/work\n")
        let blocked = CodexReadiness(installed: true, loggedIn: true, projectProblem: "o arquivo /w/.codex/config.toml define o servidor wisp-email do Codex")
        XCTAssertFalse(blocked.ready)
        XCTAssertTrue(blocked.note().contains("/w/.codex/config.toml") && blocked.note().contains("Claude"))
    }

    func testTheSessionRefusesToLaunchWhenThePreflightFindsAProblem() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran").path
        let codex = try script(in: dir, "codex", "cat >/dev/null; echo ran > \(marker)")
        let session = CodexSession(
            executable: URL(fileURLWithPath: codex), cwd: dir, resume: nil, permission: .ask, wispBinary: "/opt/wisp/venv/bin/wisp",
            preflight: { CodexPreflight(problem: "o arquivo \($0)/.codex/config.toml define o servidor wisp-email do Codex") })
        try await session.start()
        try await session.send("oi")
        var seen: SessionEvent?
        for await event in session.events {
            seen = event
            break
        }
        XCTAssertEqual(seen, .exited(code: -1, stderrTail: "o arquivo \(dir.path)/.codex/config.toml define o servidor wisp-email do Codex"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        await session.stop()
    }

    func testTheOwnedServersFromThePreflightDecideWhichBrainOverridesAreSent() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let argv = dir.appendingPathComponent("argv").path
        let codex = try script(in: dir, "codex", "cat >/dev/null; printf '%s\\n' \"$@\" > \(argv); echo '{\"type\":\"turn.completed\"}'")
        let session = CodexSession(
            executable: URL(fileURLWithPath: codex), cwd: dir, resume: nil, permission: .ask, wispBinary: "/opt/wisp/venv/bin/wisp",
            preflight: { _ in CodexPreflight(ownedByUser: [CodexCommand.brainServer]) })
        try await session.start()
        try await session.send("oi")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: argv) { try await Task.sleep(for: .milliseconds(25)) }
        let seen = try String(contentsOfFile: argv, encoding: .utf8)
        XCTAssertTrue(seen.contains("mcp_servers.wisp-email.command"))
        XCTAssertFalse(seen.contains("mcp_servers.wisp-brain."))
        await session.stop()
    }

    func testTheSessionLaunchesWhenThePreflightIsClean() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ran").path
        let codex = try script(in: dir, "codex", "cat >/dev/null; echo ran > \(marker); echo '{\"type\":\"turn.completed\"}'")
        let session = CodexSession(
            executable: URL(fileURLWithPath: codex), cwd: dir, resume: nil, permission: .ask, wispBinary: "/opt/wisp/venv/bin/wisp",
            preflight: { _ in CodexPreflight() })
        try await session.start()
        try await session.send("oi")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker) { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        await session.stop()
    }

}
