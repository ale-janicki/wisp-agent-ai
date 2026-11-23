import Foundation

/// The runtime's own books for the messages of one conversation, in submit order. The pending
/// count is derived from it, never kept as a second counter.
///
/// A message is `queued` until the runtime starts writing it to the engine, `writing` while the
/// write is suspended and `written` once the bytes reached the engine. Claude folds every message
/// already written into the running turn and answers once; Codex and the local engine queue
/// internally and answer once per message. A message that is not written yet can never be closed
/// by a result.
public struct TurnLedger: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case queued, writing, written }

    public struct Entry: Sendable, Equatable {
        public let id: UUID
        public let text: String
        public let user: String
        public let files: [String]
        public var stage: Stage
    }

    public private(set) var entries: [Entry] = []

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

    public mutating func written(_ id: UUID) { setStage(id, .written) }

    /// The write failed or never happened: the message leaves the books.
    public mutating func writeFailed(_ id: UUID) { entries.removeAll { $0.id == id } }

    /// Closes what the engine's result answers and returns it in order. What is left in
    /// `pending` still waits for its own turn.
    public mutating func result(engine: EngineKind) -> [Entry] {
        let written = entries.filter { $0.stage == .written }
        let closed = engine == .claude ? written : Array(written.prefix(1))
        let ids = Set(closed.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        return closed
    }

    public mutating func reset() { entries = [] }

    /// The engine process died: what it had is gone, what was only queued stays.
    public mutating func processRestarted() { entries.removeAll { $0.stage != .queued } }

    /// The session was lost: what the engine had goes back to the end of the queue to be
    /// written again.
    public mutating func requeueInFlight() {
        let redo = entries.filter { $0.stage != .queued }.map { entry -> Entry in
            var entry = entry
            entry.stage = .queued
            return entry
        }
        entries = entries.filter { $0.stage == .queued } + redo
    }

    private mutating func setStage(_ id: UUID, _ stage: Stage) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].stage = stage
    }
}
