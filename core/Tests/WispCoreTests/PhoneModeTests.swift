import XCTest
@testable import WispCore

final class PhoneHandoffTests: XCTestCase {
    private func request(_ summary: String = "rodar rm -r pasta") -> PermissionRequest {
        PermissionRequest(id: "r1", toolName: "Bash", summary: summary, detail: summary)
    }

    func testIdleConversationOpensAndShowsTheLastReply() {
        let text = PhoneHandoff.message(lastReply: "Pronto, criei o arquivo.", turnRunning: false, approval: nil)
        XCTAssertEqual(text, "📱 Continuando aqui.\n\nMinha última resposta:\n\nPronto, criei o arquivo.")
    }

    func testNoReplyYetIsJustTheOpening() {
        XCTAssertEqual(PhoneHandoff.message(lastReply: nil, turnRunning: false, approval: nil), PhoneHandoff.opening)
        XCTAssertEqual(PhoneHandoff.message(lastReply: "  \n ", turnRunning: false, approval: nil), PhoneHandoff.opening)
    }

    func testARunningTurnSaysItWillAnswerHere() {
        let text = PhoneHandoff.message(lastReply: "Antes.", turnRunning: true, approval: nil)
        XCTAssertTrue(text.hasSuffix("Ainda estou respondendo; mando aqui quando terminar."))
        XCTAssertTrue(text.contains("Antes."))
    }

    func testAPendingApprovalSaysWhatItAsksAndThatOnlyTheMacCanAnswer() {
        let text = PhoneHandoff.message(lastReply: nil, turnRunning: true, approval: request())
        XCTAssertTrue(text.contains("o Claude quer rodar rm -r pasta"))
        XCTAssertTrue(text.contains("só dá para responder no Mac"))
        XCTAssertFalse(text.contains("mando aqui quando terminar"), "it waits for the Mac, it does not finish by itself")
    }

    func testALongReplyIsCutAtAWordNearTheLimit() {
        let long = (0..<400).map { "palavra\($0)" }.joined(separator: " ")
        let text = PhoneHandoff.trimmed(long)
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertLessThanOrEqual(text.count, PhoneHandoff.replyLimit + 1)
        XCTAssertFalse(text.dropLast().hasSuffix(" "))
        XCTAssertTrue(long.hasPrefix(String(text.dropLast())), "cut on a word, nothing rewritten")
        XCTAssertEqual(PhoneHandoff.trimmed("curta"), "curta")
    }

    func testACutInsideACodeFenceClosesIt() {
        let long = "```\n" + String(repeating: "linha de código\n", count: 80) + "```"
        let text = PhoneHandoff.trimmed(long)
        XCTAssertEqual(text.components(separatedBy: "```").count % 2, 1)
    }

    func testLastReplyWhileATurnRunsIsTheOneBeforeTheLastUserMessage() {
        let messages = [
            ConversationMessage(role: .user, text: "oi"),
            ConversationMessage(role: .assistant, text: "olá"),
            ConversationMessage(role: .user, text: "faz isso"),
            ConversationMessage(role: .assistant, text: "parcial…"),
        ]
        XCTAssertEqual(PhoneHandoff.lastReply(in: messages, turnRunning: true), "olá")
        XCTAssertEqual(PhoneHandoff.lastReply(in: messages, turnRunning: false), "parcial…")
        XCTAssertNil(PhoneHandoff.lastReply(in: [], turnRunning: false))
        XCTAssertNil(PhoneHandoff.lastReply(in: [messages[0]], turnRunning: true))
    }
}

final class PhoneModeRecordAndCommandTests: XCTestCase {
    func testRecordDecodesOldFilesWithPhoneModeOff() throws {
        let json = #"{"id":"6F0E5C42-0000-4000-8000-000000000001","title":"x","updatedAt":0}"#
        XCTAssertFalse(try JSONDecoder().decode(ConversationRecord.self, from: Data(json.utf8)).awayOnPhone)
    }

    func testRecordRoundTripsPhoneMode() throws {
        let record = ConversationRecord(id: UUID(), sessionId: "s", title: "t", updatedAt: Date(timeIntervalSince1970: 0), awayOnPhone: true)
        let data = try JSONEncoder().encode(record)
        XCTAssertTrue(try JSONDecoder().decode(ConversationRecord.self, from: data).awayOnPhone)
    }

    func testDisallowedToolsComeBeforeThePermissionPromptTool() {
        XCTAssertEqual(
            ClaudeCommand.arguments(model: nil, resume: "abc", disallowedTools: ["AskUserQuestion"]),
            ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--replay-user-messages",
             "--resume", "abc", "--disallowedTools", "AskUserQuestion", "--permission-prompt-tool", "stdio"]
        )
    }

    private func fixture(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("cli/tests/fixtures/contract/\(name)"), encoding: .utf8)
    }

    func testPhoneInstructionMatchesTheBotsFixture() throws {
        XCTAssertEqual(AgentInstructions.onThePhone, try fixture("phone-instruction.txt"))
    }

    func testPhoneModeAddsTheSentenceAndTurnsTheQuestionToolOff() {
        let away = AgentInstructions.context(thread: 42, wispBinary: "/bin/wisp", awayOnPhone: true)
        XCTAssertTrue(away.prompt.hasSuffix(AgentInstructions.onThePhone))
        XCTAssertEqual(away.disallowedTools, ["AskUserQuestion"])
        let home = AgentInstructions.context(thread: 42, wispBinary: "/bin/wisp")
        XCTAssertFalse(home.prompt.contains(AgentInstructions.onThePhone))
        XCTAssertTrue(home.disallowedTools.isEmpty)
        XCTAssertNotEqual(away, home, "a process started at home restarts when phone mode is on")
        let bare = AgentInstructions.context(thread: nil, wispBinary: nil, awayOnPhone: true)
        XCTAssertEqual(bare.prompt, AgentInstructions.appFiles + "\n\n" + AgentInstructions.macTools + "\n\n" + AgentInstructions.onThePhone)
    }
}
