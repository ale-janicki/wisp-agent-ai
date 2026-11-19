import Foundation

public enum ConversationTitle {
    public static let fallbackLimit = 32
    public static let generatedLimit = 40
    public static let timeout: TimeInterval = 20

    public static func fallback(from text: String, limit: Int = fallbackLimit) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cut(flat, limit: limit, hardCut: true)
    }

    public static func sanitize(_ raw: String, limit: Int = generatedLimit) -> String? {
        guard let line = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        var text = line
        let strip = CharacterSet(charactersIn: "\"'`“”‘’«»*_#>-• ")
        text = text.trimmingCharacters(in: strip)
        if text.lowercased().hasPrefix("título:") || text.lowercased().hasPrefix("title:") {
            text = String(text[text.index(after: text.firstIndex(of: ":")!)...]).trimmingCharacters(in: strip)
        }
        text = text.trimmingCharacters(in: strip.union(CharacterSet(charactersIn: ".,;:!?…")))
        guard !text.isEmpty, text.split(separator: " ").count <= 8 else { return nil }
        let capped = cut(text, limit: limit, hardCut: false)
        return capped.isEmpty ? nil : capped
    }

    public static func prompt(user: String, reply: String) -> String {
        """
        Escreva o título de uma conversa entre um usuário e um assistente.
        Regras: 2 a 4 palavras, no idioma da mensagem do usuário, só a primeira letra maiúscula (nomes próprios à parte), \
        sem aspas, sem ponto final, sem emoji. Responda SOMENTE com o título.

        Mensagem do usuário:
        \(String(user.prefix(1500)))

        Início da resposta:
        \(String(reply.prefix(800)))
        """
    }

    public static func generate(
        executable: URL, user: String, reply: String, environment: [String: String]? = nil
    ) -> String? {
        let arguments = [
            "-p", "--model", "haiku", "--no-session-persistence", "--output-format", "text",
            "--tools", "", "--disable-slash-commands", "--strict-mcp-config", "--setting-sources", "",
        ]
        var env = environment ?? ProcessInfo.processInfo.environment
        env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        let result = CommandRunner.run(
            executable: executable, arguments: arguments, stdin: Data(prompt(user: user, reply: reply).utf8),
            environment: env, timeout: timeout)
        guard case .success(let output) = result, !output.timedOut, output.status == 0,
              let text = String(data: output.stdout, encoding: .utf8) else { return nil }
        return sanitize(text)
    }

    private static func cut(_ text: String, limit: Int, hardCut: Bool) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if text[text.index(text.startIndex, offsetBy: limit)] == " " { return head.trimmingCharacters(in: .whitespaces) }
        if let space = head.lastIndex(of: " ") {
            return String(head[..<space]).trimmingCharacters(in: .whitespaces)
        }
        return hardCut ? head : ""
    }
}
