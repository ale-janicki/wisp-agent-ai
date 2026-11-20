import Foundation

public enum AgentInstructions {
    public static let telegramFiles = """
    To send the user a file or an image (screenshots and images you create too) in this Telegram topic, run
    `"$WISP_BIN" topic enviar --thread="$WISP_TOPIC_THREAD" <absolute file>` (add --legenda="text" for a caption).
    Never call the Telegram API directly and never read the bot token; files go only through `wisp topic enviar`.
    A guard blocks direct API use and token reads.
    Never say you cannot send files.

    """

    public static let appFiles = """
    The user is reading the Wisp app: "here" means the app. To give the user a file or an image, \
    reply with a Markdown link to its absolute path, like [name](file:///abs/path/name.ext) (percent-encode spaces as %20); \
    the app opens it on click. Write normal Markdown, never HTML tags.
    Never call the Telegram API directly and never read the bot token.
    A guard blocks direct API use and token reads.
    Never say you cannot send files.
    """

    public static let macTools = """
    Mac tools: prefer these over ad-hoc shell commands; run them as `"${WISP_BIN:-wisp}" <command>`. Each prints one plain pt-BR result you can relay.
    `arquivos buscar "<text>" [--tipo pdf|imagem|...] [--desde 7d] [--pasta <dir>]` finds the user's files by name and content, newest first; then hand the file over the way you hand over any file in this conversation.
    `arquivos organizar <folder>` only shows a plan; always run it without --aplicar first, tell the user the plan in plain words and apply it (`--aplicar`) only after they agree. It never deletes or overwrites; `arquivos desfazer` reverts the last one.
    `mac abrir <app|file|url>`, `mac volume <0-100|mudo>`, `mac notificar "<text>"`, `mac print [--janela]` (prints the path of a screenshot, send it to the user; `--janela` needs someone at the Mac to click the window, so never use it from Telegram), `mac bateria`, `mac nao-perturbe` (status only).
    If a result says a macOS permission is missing, tell the user where to grant it; never work around it.
    """

    public static let appSharedNote = """

    This conversation is also a Telegram topic; files you link here are sent to the topic automatically. \
    Only if the user explicitly asks to send it to Telegram/the phone, run \
    `"$WISP_BIN" topic enviar --thread="$WISP_TOPIC_THREAD" <absolute file>`.
    """

    public static let agenda = """
    For anything about the user's schedule, meetings or reminders, use the Mac's own Calendar and Reminders through `"$WISP_BIN" agenda <command>` (JSON output): eventos (--hoje, --semana, --de ISO --ate ISO, --calendario NOME), criar-evento, editar-evento, apagar-evento, lembretes (--pendentes), criar-lembrete, concluir-lembrete, calendarios. Run it with no command to see every option.
    Never guess a time or take it from notes: ask the command. Before you create, edit or delete anything, tell the user what you are about to do and wait for a yes. If the command says a permission is missing, pass its message on to the user.
    """

    public static let onThePhone = "The user is on the phone: ask any question as plain text at the end of your reply."

    public static let phoneDisallowedTools = ["AskUserQuestion"]

    public struct Context: Equatable, Sendable {
        public let prompt: String
        public let environment: [String: String]
        public let thread: Int?
        public let awayOnPhone: Bool

        public var disallowedTools: [String] { awayOnPhone ? AgentInstructions.phoneDisallowedTools : [] }
    }

    public static func context(thread: Int?, wispBinary: String?, agendaBinary: String? = nil, awayOnPhone: Bool = false) -> Context {
        let phone = awayOnPhone ? "\n\n" + onThePhone : ""
        let base = appFiles + "\n\n" + macTools
        let bin = wispBinary.flatMap { $0.isEmpty ? nil : $0 }
        var environment = bin.map { ["WISP_BIN": $0] } ?? [:]
        if bin != nil, let agendaBinary, !agendaBinary.isEmpty { environment["WISP_AGENDA_BIN"] = agendaBinary }
        let agendaNote = bin == nil ? "" : "\n\n" + agenda
        guard let thread, bin != nil else {
            return Context(prompt: base + agendaNote + phone, environment: environment, thread: nil, awayOnPhone: awayOnPhone)
        }
        environment["WISP_TOPIC_THREAD"] = String(thread)
        return Context(prompt: base + appSharedNote + agendaNote + phone, environment: environment, thread: thread, awayOnPhone: awayOnPhone)
    }
}
