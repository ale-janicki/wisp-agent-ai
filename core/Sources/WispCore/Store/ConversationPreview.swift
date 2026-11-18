import Foundation

/// Who wrote the last message of a conversation.
public enum PreviewSide: String, Codable, Sendable {
    case user, agent
}

/// The one-line "last message" under a conversation row: built once when a message is sent or a reply lands
/// (stored on the record), or, for older records and Telegram topics, from the tail of the session transcript.
public enum ConversationPreview {
    public static let limit = 120
    public static let userPrefix = "Você: "
    private static let tailSizes = [64 * 1024, 512 * 1024, 4 * 1024 * 1024]

    /// Single line, whitespace collapsed, an attachment block as "📎 foto" / "📎 2 fotos · caption", cut at `limit`.
    public static func line(_ text: String) -> String {
        let source: String
        if let attachments = MessageAttachments.parse(text) ?? MessageAttachments.unparsed(text) {
            source = "📎 " + attachments.summary
        } else {
            source = text
        }
        let collapsed = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// What the row shows: an agent reply as is, the user's message after "Você: ". nil when there is nothing.
    public static func display(_ preview: String?, from side: PreviewSide?) -> String? {
        guard let preview, !preview.isEmpty else { return nil }
        return side == .user ? userPrefix + preview : preview
    }

    /// The last user or assistant message in `messages`, as a preview.
    public static func last(of messages: [ConversationMessage]) -> (text: String, from: PreviewSide)? {
        for message in messages.reversed() {
            guard message.role == .user || message.role == .assistant else { continue }
            let text = line(message.text)
            if !text.isEmpty { return (text, message.role == .user ? .user : .agent) }
        }
        return nil
    }

    /// The preview of a JSONL tail; a cut first line (the read began mid-file) is dropped.
    public static func fromTail(_ data: Data, startsMidFile: Bool, statusPrefix: String?, telegramHTML: Bool) -> (text: String, from: PreviewSide)? {
        var body = data
        if startsMidFile {
            guard let newline = body.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            body = Data(body[body.index(after: newline)...])
        }
        return last(of: TranscriptReader.messages(fromJSONL: body, statusPrefix: statusPrefix, telegramHTML: telegramHTML))
    }

    /// Reads only the end of the session file (growing the window while it finds no message); never the whole file.
    public static func load(
        sessionId: String,
        cwd: String,
        statusPrefix: String?,
        telegramHTML: Bool = false,
        projectsRoot: URL = TranscriptReader.defaultProjectsRoot
    ) -> (text: String, from: PreviewSide)? {
        guard let url = TranscriptReader.locate(sessionId: sessionId, cwd: cwd, projectsRoot: projectsRoot),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        for window in tailSizes {
            let start = size > UInt64(window) ? size - UInt64(window) : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
            if let found = fromTail(data, startsMidFile: start > 0, statusPrefix: statusPrefix, telegramHTML: telegramHTML) { return found }
            if start == 0 { return nil }
        }
        return nil
    }
}
