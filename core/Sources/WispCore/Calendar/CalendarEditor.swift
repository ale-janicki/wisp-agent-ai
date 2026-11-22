import Foundation

public enum CalendarEditorError: Error, Equatable, LocalizedError {
    case readOnly(String)
    case invalidRange

    public var errorDescription: String? {
        switch self {
        case .readOnly(let name): "\"\(name)\" é somente leitura"
        case .invalidRange: "o fim do evento ficaria antes do início"
        }
    }
}

public actor CalendarEditor {
    public enum Inverse: Sendable {
        case deleteCreated(EventRef)
        case restore(EventRef, EventEdit, RecurrenceScope)
        case recreate(EventDraft)
    }

    public struct Entry: Sendable {
        public let label: String
        public let inverse: Inverse
    }

    private let backend: any CalendarBackend
    private var stack: [Entry] = []
    private let limit: Int

    public init(backend: any CalendarBackend, limit: Int = 30) {
        self.backend = backend
        self.limit = limit
    }

    public var canUndo: Bool { !stack.isEmpty }
    public var undoLabel: String? { stack.last?.label }

    private func push(_ label: String, _ inverse: Inverse) {
        stack.append(Entry(label: label, inverse: inverse))
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
    }

    public func create(_ draft: EventDraft) async throws -> CalEvent {
        guard draft.end >= draft.start else { throw CalendarEditorError.invalidRange }
        let made = try await backend.create(draft)
        push("criar \"\(made.title)\"", .deleteCreated(EventRef(id: made.id)))
        return made
    }

    public func update(_ event: CalEvent, edit: EventEdit, scope requested: RecurrenceScope?) async throws -> CalEvent {
        guard event.writable else { throw CalendarEditorError.readOnly(event.title) }
        guard !edit.isEmpty else { return event }
        let scope = RecurrenceScope.resolved(requested, for: event)
        let newStart = edit.start ?? event.start, newEnd = edit.end ?? event.end
        guard newEnd >= newStart else { throw CalendarEditorError.invalidRange }
        var applied = edit
        var before = EventEdit.restoring(event)
        if scope == .all, event.isRecurring, edit.start != nil || edit.end != nil {
            let master = try await backend.event(ref: EventRef(id: event.id))
            let startShift = edit.start.map { $0.timeIntervalSince(event.start) } ?? 0
            let endShift = edit.end.map { $0.timeIntervalSince(event.end) } ?? 0
            applied.start = edit.start == nil ? nil : master.start.addingTimeInterval(startShift)
            applied.end = edit.end == nil ? nil : master.end.addingTimeInterval(endShift)
            before.start = master.start
            before.end = master.end
        }
        let result = try await backend.update(ref: event.ref, edit: applied, scope: scope)
        let target = scope == .all ? EventRef(id: result.id) : result.ref
        push("alterar \"\(event.title)\"", .restore(target, before, scope == .all ? .all : .thisOnly))
        return result
    }

    public func delete(_ event: CalEvent, scope requested: RecurrenceScope?) async throws {
        guard event.writable else { throw CalendarEditorError.readOnly(event.title) }
        let scope = RecurrenceScope.resolved(requested, for: event)
        var snapshot = EventDraft(event)
        if scope != .all { snapshot.recurrence = nil }
        try await backend.delete(ref: event.ref, scope: scope)
        push("apagar \"\(event.title)\"", .recreate(snapshot))
    }

    public func undo() async throws -> String? {
        guard let entry = stack.popLast() else { return nil }
        do {
            switch entry.inverse {
            case .deleteCreated(let ref): try await backend.delete(ref: ref, scope: .all)
            case .restore(let ref, let edit, let scope): _ = try await backend.update(ref: ref, edit: edit, scope: scope)
            case .recreate(let draft): _ = try await backend.create(draft)
            }
        } catch {
            stack.append(entry)
            throw error
        }
        return entry.label
    }
}
