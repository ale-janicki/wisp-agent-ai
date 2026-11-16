import XCTest
@testable import WispCore

private actor ResultInbox {
    struct Item { let sessionId: String; let at: Date }
    private(set) var items: [Item] = []
    private(set) var failure: String?
    func add(_ sessionId: String) { items.append(Item(sessionId: sessionId, at: Date())) }
    func fail(_ message: String) { failure = message }
}

final class LiveAgentTests: XCTestCase {
    func testTwoTurnsOneSession() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WISP_LIVE"] == "1", "set WISP_LIVE=1")
        let executable = try ClaudeLocator.resolve(configured: nil)
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let session = AgentSession(executable: executable, cwd: cwd, model: "haiku", resume: nil)
        let inbox = ResultInbox()
        let stream = session.events
        let reader = Task {
            for await event in stream {
                switch event {
                case .claude(.result(let sessionId, _, _, _)): await inbox.add(sessionId)
                case .exited(let code, let tail): await inbox.fail("exited \(code): \(tail)")
                default: break
                }
            }
        }
        try await session.start()

        func waitForResults(_ count: Int, timeout: TimeInterval) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while await inbox.items.count < count {
                if let failure = await inbox.failure {
                    XCTFail(failure)
                    throw CancellationError()
                }
                if Date() > deadline {
                    XCTFail("timed out after \(Int(timeout)) s waiting for result \(count)")
                    await session.stop()
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        let began1 = Date()
        try await session.send("Reply with the single word: one")
        try await waitForResults(1, timeout: 120)
        let began2 = Date()
        try await session.send("Reply with the single word: two")
        try await waitForResults(2, timeout: 120)

        let items = await inbox.items
        let first = items[0].at.timeIntervalSince(began1)
        let second = items[1].at.timeIntervalSince(began2)
        print("LIVE first=\(first)s second=\(second)s session=\(items[0].sessionId)")
        await session.stop()
        reader.cancel()

        XCTAssertFalse(items[0].sessionId.isEmpty)
        XCTAssertEqual(items[0].sessionId, items[1].sessionId)
        XCTAssertLessThan(second, first)
    }
}
