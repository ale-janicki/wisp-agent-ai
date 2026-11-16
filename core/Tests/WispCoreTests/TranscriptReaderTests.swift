import XCTest
@testable import WispCore

final class TranscriptReaderTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/transcript", withExtension: "jsonl"))
        return try Data(contentsOf: url)
    }

    func testKeepsRealPromptsAndAssistantTextWithoutStatus() throws {
        let messages = TranscriptReader.messages(fromJSONL: try fixture(), statusPrefix: "STATUS ·")
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(messages.map(\.text), [
            "what time is it?",
            "It is noon.\n\nMore detail.",
            "thanks",
        ])
    }

    func testWithoutPrefixStatusStays() throws {
        let messages = TranscriptReader.messages(fromJSONL: try fixture(), statusPrefix: nil)
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[1].text, "It is noon.\n\nMore detail.\n\nSTATUS · demo · ok\nTeu: nada")
        XCTAssertEqual(messages[3].text, "STATUS · only status")
    }

    func testSkipsSyntheticInterruptionsAndSyntheticAssistantText() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}"#,
            #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user for tool use]"}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"No response requested."}]}}"#,
            #"{"type":"assistant","message":{"model":"claude-x","role":"assistant","content":[{"type":"text","text":"real reply"}]}}"#,
        ].joined(separator: "\n")
        let messages = TranscriptReader.messages(fromJSONL: Data(lines.utf8), statusPrefix: nil)
        XCTAssertEqual(messages.map(\.text), ["hello", "real reply"])
    }

    func testProjectDirectoryName() {
        XCTAssertEqual(TranscriptReader.projectDirectoryName(forCwd: "/Users/test"), "-Users-test")
        XCTAssertEqual(TranscriptReader.projectDirectoryName(forCwd: "/Users/test/.claude"), "-Users-test--claude")
        XCTAssertEqual(TranscriptReader.projectDirectoryName(forCwd: "/a/iCloud~md~x/b c"), "-a-iCloud-md-x-b-c")
        XCTAssertEqual(TranscriptReader.projectDirectoryName(forCwd: "/Users/test/"), "-Users-test")
    }

    func testLocateFindsCwdDirectoryThenScansOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = root.appendingPathComponent("-Users-test")
        let other = root.appendingPathComponent("-Users-test-elsewhere")
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data().write(to: expected.appendingPathComponent("abc.jsonl"))
        try Data().write(to: other.appendingPathComponent("def.jsonl"))

        XCTAssertEqual(
            TranscriptReader.locate(sessionId: "abc", cwd: "/Users/test", projectsRoot: root)?.lastPathComponent,
            "abc.jsonl"
        )
        XCTAssertEqual(
            TranscriptReader.locate(sessionId: "def", cwd: "/Users/test", projectsRoot: root)?.deletingLastPathComponent().lastPathComponent,
            "-Users-test-elsewhere"
        )
        XCTAssertNil(TranscriptReader.locate(sessionId: "nope", cwd: "/Users/test", projectsRoot: root))
        XCTAssertNil(TranscriptReader.locate(sessionId: "../abc", cwd: "/Users/test", projectsRoot: root))
    }

    func testLoadMissingIsNil() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(TranscriptReader.load(sessionId: "x", cwd: "/Users/test", statusPrefix: nil, projectsRoot: root))
    }
}
