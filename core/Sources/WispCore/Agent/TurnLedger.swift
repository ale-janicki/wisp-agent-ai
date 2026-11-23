import Foundation

/// The runtime's own books for the messages of one conversation, in submit order. The pending
/// count is derived from it, never kept as a second counter.
///
/// A message is `queued` until the runtime starts writing it to the engine, `writing` while the
/// write is suspended and `written` once the bytes reached the engine.
///
/// Claude echoes every stdin message when it consumes it (`--replay-user-messages`): an echo
/// before a result means the message was folded into that turn, an echo after it means the
/// message starts its own. A result closes exactly the consumed messages. Without any echo (an
/// engine that does not replay) the ledger falls back to what a result implies: it closes every
/// written message and covers the ones still being written. Codex and the local engine queue
/// internally and answer once per message.
public struct TurnLedger: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case queued, writing, written }

    public struct Entry: Sendable, Equatable {
        public let id: UUID
        public let text: String
        public let user: String
        public let files: [String]
        public var stage: Stage
        public var consumed = false
        public var covered = false
    }

    public private(set) var entries: [Entry] = []
    private var echoes = false

    public init() {}

    /// Messages still waiting for their answer, written or not.
    public var pending: Int { entries.count }
    /// Messages the engine has, or is about to receive.
    public var inFlight: Int { entries.filter { $0.stage != .queued }.count }
    public var inFlightEntries: [Entry] { entries.filter { $0.stage != .queued } }

    public mutating func submit(id: UUID, text: String, user: String, files: [String]) {
        entries.append(Entry(id: id, text: text, user: user, files: files, stage: .queued))
    }

    public mutating func writing(_ id: UUID) { setStage(id, .writing) }

    /// The bytes reached the engine. Returns the entry when a result already covered it while the
    /// write was suspended: it has no result of its own coming and leaves the books here.
    public mutating func written(_ id: UUID) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        if entries[index].covered { return entries.remove(at: index) }
        entries[index].stage = .written
        return nil
    }

    /// The write failed or never happened: the message leaves the books.
    public mutating func writeFailed(_ id: UUID) { entries.removeAll { $0.id == id } }

    /// The engine echoed the oldest message it had not consumed yet.
    public mutating func consumed() {
        echoes = true
        guard let index = entries.firstIndex(where: { $0.stage != .queued && !$0.consumed }) else { return }
        entries[index].consumed = true
    }

    /// Closes what the engine's result answers and returns it in order. What is left in
    /// `pending` still waits for its own turn. An error closes everything the engine had.
    public mutating func result(engine: EngineKind, isError: Bool = false) -> [Entry] {
        let closed: [Entry]
        if isError {
            closed = inFlightEntries
        } else if engine != .claude {
            closed = Array(entries.filter { $0.stage == .written }.prefix(1))
        } else if echoes {
            let seen = entries.filter(\.consumed)
            closed = seen.isEmpty ? Array(entries.filter { $0.stage == .written }.prefix(1)) : seen
        } else {
            closed = entries.filter { $0.stage == .written }
            for index in entries.indices where entries[index].stage == .writing { entries[index].covered = true }
        }
        let ids = Set(closed.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        return closed
    }

    public mutating func reset() {
        entries = []
        echoes = false
    }

    /// The engine process died: what it had is gone, what was only queued stays.
    public mutating func processRestarted() {
        entries.removeAll { $0.stage != .queued }
        echoes = false
    }

    /// The session was lost: what the engine had goes back to the end of the queue to be
    /// written again.
    public mutating func requeueInFlight() {
        let redo = entries.filter { $0.stage != .queued }.map { entry -> Entry in
            var entry = entry
            entry.stage = .queued
            entry.consumed = false
            entry.covered = false
            return entry
        }
        entries = entries.filter { $0.stage == .queued } + redo
        echoes = false
    }

    /// One Telegram post for the messages a single result closed: the reply is theirs together.
    public static func mirror(of closed: [Entry]) -> (user: String, files: [String])? {
        guard !closed.isEmpty else { return nil }
        return (closed.map(\.user).joined(separator: "\n"), closed.flatMap(\.files))
    }

    private mutating func setStage(_ id: UUID, _ stage: Stage) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].stage = stage
    }
}
