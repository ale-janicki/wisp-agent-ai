import XCTest
@testable import WispCore

final class AgentSessionTests: XCTestCase {
    private func makeFakeClaude() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = try XCTUnwrap(Bundle.module.url(forResource: "fake-claude", withExtension: "sh", subdirectory: "Fixtures"))
        let target = dir.appendingPathComponent("fake-claude.sh")
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target
    }

    private func collect(
        _ session: AgentSession,
        until done: @Sendable @escaping ([SessionEvent]) -> Bool,
        timeout: Duration = .seconds(10)
    ) async -> [SessionEvent] {
        let stream = session.events
        return await withTaskGroup(of: [SessionEvent].self) { group in
            group.addTask {
                var seen: [SessionEvent] = []
                for await event in stream {
                    seen.append(event)
                    if done(seen) { break }
                }
                return seen
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    func testEmitsExitedOnCrash() async throws {
        let session = AgentSession(
            executable: try makeFakeClaude(), cwd: FileManager.default.temporaryDirectory,
            model: nil, resume: nil, environmentOverrides: ["FAKE_CRASH": "1"]
        )
        try await session.start()
        let events = await collect(session) { seen in
            seen.contains { if case .exited = $0 { return true } else { return false } }
        }
        XCTAssertEqual(events.first, .claude(.initialized(sessionId: "fake-1", model: "fake", subscription: true)))
        guard case .exited(let code, _)? = events.last else { return XCTFail("no exited event: \(events)") }
        XCTAssertEqual(code, 3)
    }

    func testSendWhileBusyIsWritten() async throws {
        let session = AgentSession(
            executable: try makeFakeClaude(), cwd: FileManager.default.temporaryDirectory,
            model: nil, resume: nil, environmentOverrides: ["FAKE_WAIT2": "1"]
        )
        try await session.start()
        try await session.send("one")
        try await session.send("two")
        let events = await collect(session) { seen in resultTexts(seen).count == 2 }
        XCTAssertEqual(resultTexts(events), ["one", "two"])
        await session.stop()
    }

    func testRunFailureFinishesStream() async throws {
        let session = AgentSession(
            executable: try makeFakeClaude(),
            cwd: URL(fileURLWithPath: "/nonexistent/wisp-\(UUID().uuidString)"),
            model: nil, resume: nil
        )
        do {
            try await session.start()
            XCTFail("expected start to throw")
        } catch {}
        var seen: [SessionEvent] = []
        for await event in session.events { seen.append(event) }
        guard case .exited(let code, let tail)? = seen.last else { return XCTFail("no exited: \(seen)") }
        XCTAssertEqual(code, -1)
        XCTAssertFalse(tail.isEmpty)
    }

    func testDroppingSessionTerminatesChild() async throws {
        let executable = try makeFakeClaude()
        var pid: Int32 = 0
        do {
            let session = AgentSession(
                executable: executable, cwd: FileManager.default.temporaryDirectory,
                model: nil, resume: nil, environmentOverrides: ["FAKE_WAIT2": "1"]
            )
            try await session.start()
            pid = try XCTUnwrap(session.processIdentifier)
            XCTAssertEqual(kill(pid, 0), 0)
        }
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "child \(pid) still alive after session dropped")
    }

    func testSendBeforeStartThrows() async throws {
        let session = AgentSession(
            executable: try makeFakeClaude(), cwd: FileManager.default.temporaryDirectory,
            model: nil, resume: nil
        )
        do {
            try await session.send("x")
            XCTFail("expected notRunning")
        } catch {
            XCTAssertEqual(error as? AgentError, .notRunning)
        }
    }

    func testStopEndsStreamAndSendAfterExitThrows() async throws {
        let session = AgentSession(
            executable: try makeFakeClaude(), cwd: FileManager.default.temporaryDirectory,
            model: nil, resume: nil
        )
        try await session.start()
        await session.stop()
        let events = await collect(session) { seen in
            seen.contains { if case .exited = $0 { return true } else { return false } }
        }
        guard case .exited(let code, _)? = events.last else { return XCTFail("no exited: \(events)") }
        XCTAssertEqual(code, 0)
        do {
            try await session.send("late")
            XCTFail("expected notRunning")
        } catch {
            XCTAssertEqual(error as? AgentError, .notRunning)
        }
    }
}

private func resultTexts(_ events: [SessionEvent]) -> [String] {
    events.compactMap { if case .claude(.result(_, let text, _, _)) = $0 { return text } else { return nil } }
}
