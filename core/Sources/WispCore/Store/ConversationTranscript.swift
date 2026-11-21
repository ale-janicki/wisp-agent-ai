import Foundation

public struct TranscriptEntry: Equatable, Sendable {
    public enum Kind: String, Sendable { case session, user, assistant }

    public var kind: Kind
    public var at: String
    public var surface: String?
    public var text: String?
    public var engine: String?
    public var model: String?
    public var session: String?
    public var reason: String?

    public init(
        kind: Kind, at: String, surface: String? = nil, text: String? = nil, engine: String? = nil,
        model: String? = nil, session: String? = nil, reason: String? = nil
    ) {
        self.kind = kind
        self.at = at
        self.surface = surface
        self.text = text
        self.engine = engine
        self.model = model
        self.session = session
        self.reason = reason
    }
}

public enum ConversationTranscript {
    public static let version = 1
    public static let recentMessages = 6
    public static let recentChars = 3000
    public static let olderChars = 400
    public static let budgetChars = 24000
    public static let header = "[Wisp conversation memory: this conversation continues from Wisp's own transcript because the engine session was not available. Older messages are shortened.]"
    public static let footer = "[end of Wisp conversation memory]"
    public static let rebuiltNote = "↻ a sessão do Claude não estava aqui; retomei pela conversa guardada no Wisp."

    public static func rebuiltNote(engine: EngineKind) -> String {
        "↻ a sessão do \(engine.displayName) não estava aqui; retomei pela conversa guardada no Wisp."
    }

    public static let noWorkspaceNote = "o Codex não tem uma pasta de trabalho segura neste Mac (a pasta do Wisp é a pasta pessoal ou fica acima dela); esta conversa roda no Claude"

    public static func switchedNote(to engine: EngineKind) -> String {
        "↻ agora quem responde é o \(engine.displayName); ele retomou pela conversa guardada no Wisp."
    }
    public static let codexLostSession = "codex session not found: the saved conversation will be replayed"
    private static let lostSessionMarkers = ["no conversation found with session id", codexLostSession]

    public static func isLostSession(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lostSessionMarkers.contains { lowered.contains($0) }
    }

    public static func stamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func encode(_ entry: TranscriptEntry) throws -> String {
        var object: [String: Any] = ["v": version, "at": entry.at, "kind": entry.kind.rawValue]
        let optional: [(String, String?)] = [
            ("surface", entry.surface), ("text", entry.text), ("engine", entry.engine),
            ("model", entry.model), ("session", entry.session), ("reason", entry.reason),
        ]
        for (key, value) in optional { if let value { object[key] = value } }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ data: Data) -> [TranscriptEntry] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let raw = object["kind"] as? String, let kind = TranscriptEntry.Kind(rawValue: raw)
            else { return nil }
            return TranscriptEntry(
                kind: kind, at: object["at"] as? String ?? "", surface: object["surface"] as? String,
                text: object["text"] as? String, engine: object["engine"] as? String,
                model: object["model"] as? String, session: object["session"] as? String,
                reason: object["reason"] as? String)
        }
    }

    public static func context(_ entries: [TranscriptEntry]) -> String? {
        let messages = entries.filter {
            ($0.kind == .user || $0.kind == .assistant) && !($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard messages.contains(where: { $0.kind == .assistant }) else { return nil }
        var kept: [String] = []
        var used = 0
        for (index, entry) in messages.reversed().enumerated() {
            let limit = index < recentMessages ? recentChars : olderChars
            let label = entry.kind == .user ? "User" : "Assistant"
            let block = "\(label): \(clip(entry.text ?? "", limit: limit))"
            let cost = block.unicodeScalars.count + 2
            if used + cost > budgetChars { break }
            kept.append(block)
            used += cost
        }
        guard !kept.isEmpty else { return nil }
        let omitted = messages.count - kept.count
        let notice = omitted > 0 ? ["(\(omitted) older messages not shown.)"] : []
        return ([header] + notice + kept.reversed() + [footer]).joined(separator: "\n\n")
    }

    public static func prime(_ context: String?, prompt: String) -> String {
        guard let context else { return prompt }
        return "\(context)\n\n\(prompt)"
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count > limit else { return trimmed }
        var cut = String.UnicodeScalarView()
        cut.append(contentsOf: trimmed.unicodeScalars.prefix(limit))
        return String(cut).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

public enum WispFolder {
    public static func configURL(environment: [String: String], home: URL) -> URL {
        if let explicit = environment["WISP_CONFIG"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("wisp/wisp.json")
    }

    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let data = try? Data(contentsOf: configURL(environment: environment, home: home))
        let raw = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let path = (raw?["wisp_dir"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "~/Wisp"
        let expanded = path == "~" || path.hasPrefix("~/") ? home.path + path.dropFirst() : path
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    public static func conversations(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        directory(environment: environment, home: home).appendingPathComponent("conversas", isDirectory: true)
    }
}

public final class TranscriptStore: @unchecked Sendable {
    public enum StoreError: Error, LocalizedError {
        case invalidId(String)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .invalidId(let id): "id de conversa inválido: \(id)"
            case .io(let reason): reason
            }
        }
    }

    public let folder: URL
    private let lock = NSLock()
    private var found: [String: String] = [:]
    private let stamp: @Sendable () -> String

    public init(folder: URL, stamp: @escaping @Sendable () -> String = { ConversationTranscript.stamp() }) {
        self.folder = folder
        self.stamp = stamp
    }

    public func url(conversation: String) throws -> URL {
        guard Self.valid(conversation) else { throw StoreError.invalidId(conversation) }
        return folder.appendingPathComponent("\(conversation).jsonl")
    }

    public func find(session: String?) -> String? {
        guard let session, Self.valid(session) else { return nil }
        lock.lock()
        let cached = found[session]
        lock.unlock()
        let fm = FileManager.default
        if let cached, let path = try? url(conversation: cached), fm.fileExists(atPath: path.path) { return cached }
        if let path = try? url(conversation: session), fm.fileExists(atPath: path.path) { return session }
        let needle = "\"session\":\"\(session)\""
        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let data = try? Data(contentsOf: file), String(decoding: data, as: UTF8.self).contains(needle),
                  ConversationTranscript.decode(data).contains(where: { $0.kind == .session && $0.session == session })
            else { continue }
            let id = file.deletingPathExtension().lastPathComponent
            lock.lock()
            found[session] = id
            lock.unlock()
            return id
        }
        return nil
    }

    public func entries(conversation: String) -> [TranscriptEntry] {
        guard let path = try? url(conversation: conversation), let data = try? Data(contentsOf: path) else { return [] }
        return ConversationTranscript.decode(data)
    }

    public func lastEngine(conversation: String?) -> String? {
        guard let conversation else { return nil }
        return entries(conversation: conversation).last { $0.kind == .assistant && !($0.engine ?? "").isEmpty }?.engine
    }

    public func engineSession(conversation: String?, engine: String) -> String? {
        guard let conversation else { return nil }
        return entries(conversation: conversation).last { $0.kind == .session && $0.engine == engine && $0.session != nil }?.session
    }

    public func engines(conversation: String) -> Set<String> {
        Set(entries(conversation: conversation).filter { $0.kind == .assistant }.compactMap(\.engine))
    }

    public func messages(conversation: String) -> [ConversationMessage] {
        entries(conversation: conversation).compactMap { entry in
            guard let text = entry.text, !text.isEmpty else { return nil }
            switch entry.kind {
            case .user: return ConversationMessage(role: .user, text: text)
            case .assistant: return ConversationMessage(role: .assistant, text: text)
            case .session: return nil
            }
        }
    }

    public func context(conversation: String?, dropTrailingUsers: Int = 0) -> String? {
        guard let conversation else { return nil }
        var all = entries(conversation: conversation)
        var dropped = 0
        while dropped < dropTrailingUsers, all.last?.kind == .user {
            all.removeLast()
            dropped += 1
        }
        return ConversationTranscript.context(all)
    }

    public func appendUser(conversation: String, openingSession: String?, text: String, surface: String) throws {
        try append(
            TranscriptEntry(kind: .user, at: stamp(), surface: surface, text: text),
            conversation: conversation, openingSession: openingSession)
    }

    public func appendAssistant(
        conversation: String, openingSession: String?, text: String, surface: String, engine: String, model: String?
    ) throws {
        try append(
            TranscriptEntry(
                kind: .assistant, at: stamp(), surface: surface, text: text,
                engine: engine, model: model ?? ""),
            conversation: conversation, openingSession: openingSession)
    }

    public func link(session: String, conversation: String, engine: String, reason: String) throws {
        try append(
            TranscriptEntry(
                kind: .session, at: stamp(), engine: engine, session: session, reason: reason),
            conversation: conversation, openingSession: nil)
    }

    private func append(_ entry: TranscriptEntry, conversation: String, openingSession: String?) throws {
        let path = try url(conversation: conversation)
        var lines: [String] = []
        if !FileManager.default.fileExists(atPath: path.path), let openingSession {
            lines.append(try ConversationTranscript.encode(TranscriptEntry(
                kind: .session, at: entry.at, engine: "claude", session: openingSession, reason: "new")))
        }
        lines.append(try ConversationTranscript.encode(entry))
        try Self.appendLines(lines, to: path)
    }

    private static func appendLines(_ lines: [String], to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(path.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StoreError.io(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw StoreError.io(String(cString: strerror(errno))) }
        var info = stat()
        fstat(descriptor, &info)
        var last: UInt8 = 0x0A
        let broken = info.st_size > 0 && pread(descriptor, &last, 1, info.st_size - 1) == 1 && last != 0x0A
        var payload = Data(broken ? "\n".utf8 : "".utf8)
        for line in lines { payload.append(Data((line + "\n").utf8)) }
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { write(descriptor, $0.baseAddress! + offset, payload.count - offset) }
            guard written > 0 else { throw StoreError.io(String(cString: strerror(errno))) }
            offset += written
        }
    }

    private static func valid(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count)
            && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
    }
}

public enum TranscriptHistory {
    public static func load(
        store: TranscriptStore, sessionId: String?, conversationKey: String,
        claude: (String) -> [ConversationMessage]?
    ) -> [ConversationMessage]? {
        let key = store.find(session: sessionId) ?? store.find(session: conversationKey)
        let wisp = key.map { store.messages(conversation: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        if let key, store.engines(conversation: key).contains(where: { $0 != "claude" }) { return wisp }
        guard let sessionId else { return wisp }
        return claude(sessionId) ?? wisp
    }
}
