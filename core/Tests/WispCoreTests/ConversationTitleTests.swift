import XCTest
@testable import WispCore

final class ConversationTitleTests: XCTestCase {
    func testSanitizeStripsQuotesMarkdownAndPunctuation() {
        XCTAssertEqual(ConversationTitle.sanitize("  \"Supabase do acme.\"\n"), "Supabase do acme")
        XCTAssertEqual(ConversationTitle.sanitize("**Hotfix do bot Telegram**"), "Hotfix do bot Telegram")
        XCTAssertEqual(ConversationTitle.sanitize("# Título: Revisão do PR!"), "Revisão do PR")
        XCTAssertEqual(ConversationTitle.sanitize("“Erro de conexão…”"), "Erro de conexão")
    }

    func testSanitizeTakesFirstNonEmptyLine() {
        XCTAssertEqual(ConversationTitle.sanitize("\n\nBackup do vault\nExplicação extra"), "Backup do vault")
    }

    func testSanitizeCapsAtWordBoundary() {
        let result = ConversationTitle.sanitize("Configuração completa do ambiente de testes", limit: 20)
        XCTAssertEqual(result, "Configuração")
    }

    func testSanitizeRejectsEmptyAndSentences() {
        XCTAssertNil(ConversationTitle.sanitize(""))
        XCTAssertNil(ConversationTitle.sanitize("  \n \""))
        XCTAssertNil(ConversationTitle.sanitize("Não consigo gerar um título para essa conversa porque falta contexto"))
        XCTAssertNil(ConversationTitle.sanitize("Supercalifragilisticexpialidocious-extraordinarily-long-word", limit: 40))
    }

    func testFallbackCutsAtWordBoundaryWithoutEllipsis() {
        XCTAssertEqual(
            ConversationTitle.fallback(from: "Temos uma tarefa, já vi que o supabase está dando erro"),
            "Temos uma tarefa, já vi que o")
        XCTAssertEqual(ConversationTitle.fallback(from: "Oi"), "Oi")
        XCTAssertEqual(ConversationTitle.fallback(from: "a\n\n  b   c"), "a b c")
    }

    func testFallbackHardCutsOneLongWord() {
        XCTAssertEqual(ConversationTitle.fallback(from: String(repeating: "x", count: 50)).count, 32)
    }

    func testFallbackKeepsExactlyLimitWithBoundaryAfter() {
        let text = String(repeating: "a", count: 31) + " bbb"
        XCTAssertEqual(ConversationTitle.fallback(from: text), String(repeating: "a", count: 31))
    }

    func testRecordDecodesOldFileWithoutTitleGenerated() throws {
        let json = #"{"id":"6F0E5C42-0000-4000-8000-000000000001","title":"x","updatedAt":0}"#
        let record = try JSONDecoder().decode(ConversationRecord.self, from: Data(json.utf8))
        XCTAssertFalse(record.titleGenerated)
    }
}
