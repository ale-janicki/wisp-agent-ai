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

    public static let appSharedNote = """

    This conversation is also a Telegram topic; files you link here are sent to the topic automatically. \
    Only if the user explicitly asks to send it to Telegram/the phone, run \
    `"$WISP_BIN" topic enviar --thread="$WISP_TOPIC_THREAD" <absolute file>`.
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

    public static func context(thread: Int?, wispBinary: String?, awayOnPhone: Bool = false) -> Context {
        let phone = awayOnPhone ? "\n\n" + onThePhone : ""
        guard let thread, let bin = wispBinary, !bin.isEmpty else {
            return Context(prompt: appFiles + phone, environment: [:], thread: nil, awayOnPhone: awayOnPhone)
        }
        return Context(prompt: appFiles + appSharedNote + phone, environment: ["WISP_BIN": bin, "WISP_TOPIC_THREAD": String(thread)],
                       thread: thread, awayOnPhone: awayOnPhone)
    }
}
