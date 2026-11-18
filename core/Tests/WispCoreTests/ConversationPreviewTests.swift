import XCTest
@testable import WispCore

final class ConversationPreviewTests: XCTestCase {
    private func user(_ text: String) -> String {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst(2).dropLast(2)
        return #"{"type":"user","message":{"role":"user","content":"\#(escaped)"}}"#
    }

    private func assistant(_ text: String) -> String {
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [text], options: []), encoding: .utf8)!.dropFirst(2).dropLast(2)
        return #"{"type":"assistant","message":{"role":"assistant","model":"m","stop_reason":"end_turn","content":[{"type":"text","text":"\#(escaped)"}]}}"#
    }

    func testLineCollapsesWhitespaceAndCuts() {
        XCTAssertEqual(ConversationPreview.line("  a \n\n b\t c "), "a b c")
        let long = ConversationPreview.line(String(repeating: "palavra ", count: 40))
        XCTAssertEqual(long.count, ConversationPreview.limit)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testAttachmentBlockBecomesPaperclip() {
        let block = MessageAttachments.compose(
            origin: "Wisp",
            files: [StagedAttachment(path: "/tmp/a/wisp-abcd1234-x.png", name: "wisp-abcd1234-x.png", bytes: 10)],
            caption: "olha isso"
        )
        XCTAssertEqual(ConversationPreview.line(block), "📎 1 foto · olha isso")
        let bare = MessageAttachments.compose(
            origin: "Wisp", files: [StagedAttachment(path: "/tmp/a/wisp-abcd1234-x.pdf", name: "wisp-abcd1234-x.pdf", bytes: 10)], caption: ""
        )
        XCTAssertEqual(ConversationPreview.line(bare), "📎 1 arquivo")
    }

    func testDisplayPrefixesOnlyTheUser() {
        XCTAssertEqual(ConversationPreview.display("oi", from: .user), "Você: oi")
        XCTAssertEqual(ConversationPreview.display("oi", from: .agent), "oi")
        XCTAssertNil(ConversationPreview.display("", from: .user))
        XCTAssertNil(ConversationPreview.display(nil, from: nil))
    }

    func testLastOfSkipsSystemAndTool() {
        let messages = [
            ConversationMessage(role: .user, text: "pergunta"),
            ConversationMessage(role: .assistant, text: "resposta"),
            ConversationMessage(role: .system, text: "erro"),
        ]
        let last = ConversationPreview.last(of: messages)
        XCTAssertEqual(last?.text, "resposta")
        XCTAssertEqual(last?.from, .agent)
    }

    func testTailDropsTheCutFirstLine() {
        let data = Data(("meio de uma linha cortada}\n" + user("primeira") + "\n" + assistant("fim") + "\n").utf8)
        let found = ConversationPreview.fromTail(data, startsMidFile: true, statusPrefix: nil, telegramHTML: false)
        XCTAssertEqual(found?.text, "fim")
        XCTAssertEqual(found?.from, .agent)
        XCTAssertNil(ConversationPreview.fromTail(Data("so um pedaco".utf8), startsMidFile: true, statusPrefix: nil, telegramHTML: false))
    }

    func testLoadReadsOnlyTheEndOfALargeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        let folder = root.appendingPathComponent(TranscriptReader.projectDirectoryName(forCwd: "/work/x"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var text = user("começo") + "\n"
        text += (0..<3000).map { _ in assistant(String(repeating: "x", count: 100)).replacingOccurrences(of: #""type":"assistant""#, with: #""type":"summary""#) }.joined(separator: "\n") + "\n"
        text += user("ultima do usuario") + "\n"
        try text.write(to: folder.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        let found = ConversationPreview.load(sessionId: "s1", cwd: "/work/x", statusPrefix: nil, projectsRoot: root)
        XCTAssertEqual(found?.text, "ultima do usuario")
        XCTAssertEqual(found?.from, .user)
        XCTAssertNil(ConversationPreview.load(sessionId: "nope", cwd: "/work/x", statusPrefix: nil, projectsRoot: root))
    }
}
