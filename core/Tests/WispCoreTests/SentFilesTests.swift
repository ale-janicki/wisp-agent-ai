import XCTest
@testable import WispCore

final class SentFilesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sentfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func make(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url.path
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    // MARK: Parser

    func testQuotedPathWithSpacesAndLegendaValue() {
        let command = #""$WISP_BIN" topic enviar --thread="$WISP_TOPIC_THREAD" --legenda "x y /not/a/file" "/tmp/with space/a.pdf""#
        XCTAssertEqual(SentFiles.enviarFiles(in: command, exists: { _ in true }), ["/tmp/with space/a.pdf"])
    }

    func testMultipleFilesFlagsAndSeparateValues() {
        let command = "wisp topic enviar --json --thread 42 --legenda=oi /a/1.png /b/2.txt relative.txt /a/1.png && echo /c/3"
        XCTAssertEqual(SentFiles.enviarFiles(in: command, exists: { $0 != "/b/2.txt" }), ["/a/1.png"])
        XCTAssertEqual(SentFiles.enviarFiles(in: command, exists: { _ in true }), ["/a/1.png", "/b/2.txt"])
    }

    func testTildeAndHomePathsAreExpanded() {
        let home = NSHomeDirectory()
        let command = #""$WISP_BIN" topic enviar --thread="0" ~/Library/Mobile\ Documents/x/m.html "$HOME/a.pdf""#
        XCTAssertEqual(SentFiles.enviarFiles(in: command, exists: { _ in true }),
                       [home + "/Library/Mobile Documents/x/m.html", home + "/a.pdf"])
    }

    func testOtherCommandsAndMissingFilesGiveNothing() {
        XCTAssertEqual(SentFiles.enviarFiles(in: "ls /tmp", exists: { _ in true }), [])
        XCTAssertEqual(SentFiles.enviarFiles(in: "wisp topic listar /tmp", exists: { _ in true }), [])
        XCTAssertEqual(SentFiles.enviarFiles(in: "wisp topic enviar /nope/x.pdf"), [])
    }

    func testOnlyTheWispBinaryCounts() {
        let yes: (String) -> Bool = { _ in true }
        XCTAssertEqual(SentFiles.enviarFiles(in: #"echo "wisp topic enviar /a/b.txt""#, exists: yes), [])
        XCTAssertEqual(SentFiles.enviarFiles(in: "echo wisp topic enviar /a/b.txt", exists: yes), [])
        XCTAssertEqual(SentFiles.enviarFiles(in: "grep topic enviar /a/b.txt", exists: yes), [])
        XCTAssertEqual(SentFiles.enviarFiles(in: "FOO=1 BAR=x /u/venv/bin/wisp topic enviar /a/b.txt", exists: yes), ["/a/b.txt"])
        XCTAssertEqual(SentFiles.enviarFiles(in: #"cd /x && "$WISP_BIN" topic enviar /a/c.txt"#, exists: yes), ["/a/c.txt"])
        XCTAssertEqual(SentFiles.enviarFiles(in: "echo hi; w topic enviar /a/d.txt", exists: yes), [])
    }

    func testSingleQuotesAndEscapedSpace() {
        XCTAssertEqual(SentFiles.enviarFiles(in: "wisp topic enviar '/a b/c.txt' /d\\ e/f.txt", exists: { _ in true }),
                       ["/a b/c.txt", "/d e/f.txt"])
    }

    // MARK: Cards from a transcript

    func testTranscriptGivesCardsForLinkAndEnviar() throws {
        let linked = try make("relatorio final.pdf")
        let sent = try make("manifesto.pdf")
        let encoded = linked.replacingOccurrences(of: " ", with: "%20")
        let lines = try [
            jsonLine(["type": "user", "message": ["role": "user", "content": "manda os arquivos"]]),
            jsonLine(["type": "assistant", "message": ["role": "assistant", "stop_reason": "tool_use", "content": [
                ["type": "tool_use", "id": "t1", "name": "Bash",
                 "input": ["command": "\"$WISP_BIN\" topic enviar --thread=\"$T\" --legenda \"oi\" \"\(sent)\""]],
            ]]]),
            jsonLine(["type": "user", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "content": "ok, enviados 1"],
            ]]]),
            jsonLine(["type": "assistant", "message": ["role": "assistant", "stop_reason": "end_turn", "content": [
                ["type": "text", "text": "Segue: [relatório](file://\(encoded))"],
            ]]]),
        ]
        let messages = TranscriptReader.messages(fromJSONL: Data(lines.joined(separator: "\n").utf8), statusPrefix: nil)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages[1].files, [sent, linked])
    }

    func testFailedEnviarMakesNoCard() throws {
        let sent = try make("a.png")
        let lines = try [
            jsonLine(["type": "user", "message": ["role": "user", "content": "manda"]]),
            jsonLine(["type": "assistant", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "wisp topic enviar \(sent)"]],
                ["type": "text", "text": "tentei"],
            ]]]),
            jsonLine(["type": "user", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "falhou"],
            ]]]),
        ]
        let messages = TranscriptReader.messages(fromJSONL: Data(lines.joined(separator: "\n").utf8), statusPrefix: nil)
        XCTAssertEqual(messages.last?.files, [])
    }

    // MARK: Live

    func testLiveStreamCardsAndMirrorGuard() throws {
        let sent = try make("m.pdf")
        let assistant = try jsonLine(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "id": "t9", "name": "Bash", "input": ["command": "wisp topic enviar \(sent)"]],
        ]]])
        let done = try jsonLine(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t9", "content": [["type": "text", "text": "ok"]]],
        ]]])
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "manda")
        for line in [assistant, done] {
            for event in ClaudeStreamDecoder.decode(line: line) { ConversationReducer.reduce(&state, .claude(event), statusPrefix: nil) }
        }
        ConversationReducer.reduce(&state, .claude(.text("pronto")), statusPrefix: nil)
        ConversationReducer.reduce(&state, .claude(.result(sessionId: "s", text: "pronto", isError: false, denials: [])), statusPrefix: nil)
        XCTAssertEqual(state.messages.last { $0.role == .assistant }?.files, [sent])
        XCTAssertEqual(state.sentToTelegram, [sent])
    }

    func testMirrorDedupComparesResolvedPaths() throws {
        let real = try make("r.pdf")
        let link = dir.appendingPathComponent("l.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: real))
        let other = try make("o.pdf")
        XCTAssertEqual(SentFiles.unsent([link.path, other, other], alreadySent: [real]), [other])
        XCTAssertEqual(SentFiles.unsent([real, link.path], alreadySent: []), [real])
        XCTAssertEqual(SentFiles.unsent([dir.path + "/sub/../r.pdf"], alreadySent: [real]), [])
    }

    // MARK: Hook block

    func testHookBlockIsNotAPermissionDenial() throws {
        let blocked = try jsonLine(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t2", "is_error": true,
             "content": "PreToolUse:Bash hook error: [wisp hook guard-telegram]: wisp-guard: files reach the user only through Wisp (curl)"],
        ]]])
        var state = ConversationState()
        ConversationReducer.userSent(&state, text: "oi")
        for event in ClaudeStreamDecoder.decode(line: blocked) { ConversationReducer.reduce(&state, .claude(event), statusPrefix: nil) }
        ConversationReducer.reduce(&state, .claude(.result(sessionId: "s", text: "ok", isError: false, denials: ["Bash"])), statusPrefix: nil)
        let notices = state.messages.filter { $0.role == .system }.map(\.text)
        XCTAssertEqual(notices, ["Bloqueado pela trava do Wisp: files reach the user only through Wisp (curl)"])
    }

    func testClassifier() {
        XCTAssertNil(ToolBlock.hookReason(in: "Permission to use Bash has been denied."))
        XCTAssertNil(ToolBlock.hookReason(in: "File not found"))
        XCTAssertEqual(ToolBlock.hookReason(in: "Blocked\nwisp-guard: no secrets here\nmore"), "no secrets here")
        XCTAssertNil(ToolBlock.hookReason(in: "wisp: error: no such topic"))
        XCTAssertNil(ToolBlock.hookReason(in: "PreToolUse:Read hook error: exit 2"))
        XCTAssertNil(ToolBlock.hookReason(in: "PreToolUse:Bash hook error: wisp: o cérebro não foi salvo"))
    }
}
