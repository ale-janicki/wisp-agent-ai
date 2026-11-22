import Foundation

public enum CalendarEditorError: Error, Equatable, LocalizedError {
    case readOnly(String)
    case invalidRange
    case undoTargetGone

    public var errorDescription: String? {
        switch self {
        case .readOnly(let name): "\"\(name)\" é somente leitura"
        case .invalidRange: "o fim do evento ficaria antes do início"
        case .undoTargetGone: "Esse evento não existe mais, então não há o que desfazer."
        }
    }
}

public struct UndoResult: Equatable, Sendable {
    public let label: String
    public let caveat: String?

    public var message: String { caveat.map { "\(label). \($0)" } ?? label }
}

public actor CalendarEditor {
    public enum Inverse: Sendable {
        case deleteCreated(EventRef)
        case restore(EventRef, EventEdit, RecurrenceScope, caveat: String?)
        case recreate(EventDraft, originalID: String, caveat: String?)
    }

    public struct Entry: Sendable {
        public let label: String
        public var inverse: Inverse
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
        let scope = RecurrenceScope.resolved(requested, for: event)
        var applied = edit
        if scope == .thisOnly || event.hasMultipleRules { applied.recurrence = .keep }
        guard !applied.isEmpty else { return event }
        let newStart = applied.start ?? event.start, newEnd = applied.end ?? event.end
        guard newEnd >= newStart else { throw CalendarEditorError.invalidRange }
        var before = EventEdit.restoring(event, matching: applied)
        if scope == .all, event.isRecurring, applied.start != nil || applied.end != nil {
            let master = try await backend.event(ref: EventRef(id: event.id))
            let startShift = applied.start.map { $0.timeIntervalSince(event.start) } ?? 0
            let endShift = applied.end.map { $0.timeIntervalSince(event.end) } ?? 0
            applied.start = applied.start == nil ? nil : master.start.addingTimeInterval(startShift)
            applied.end = applied.end == nil ? nil : master.end.addingTimeInterval(endShift)
            if before.start != nil { before.start = master.start }
            if before.end != nil { before.end = master.end }
        }
        let result = try await backend.update(ref: event.ref, edit: applied, scope: scope, expectedModified: event.modified)
        let target = scope == .all ? EventRef(id: result.id) : result.ref
        let splitNote = scope == .thisAndFuture && event.isRecurring
            ? "a série que foi dividida não é juntada de volta: as ocorrências seguintes continuam numa série separada" : nil
        push("alterar \"\(event.title)\"", .restore(target, before, scope, caveat: splitNote))
        return result
    }

    public func delete(_ event: CalEvent, scope requested: RecurrenceScope?) async throws {
        guard event.writable else { throw CalendarEditorError.readOnly(event.title) }
        let scope = RecurrenceScope.resolved(requested, for: event)
        var snapshot = EventDraft(event)
        if scope == .all, event.isRecurring, let master = try? await backend.event(ref: EventRef(id: event.id)) { snapshot = EventDraft(master) }
        var caveats: [String] = []
        if event.isRecurring {
            switch scope {
            case .thisOnly:
                snapshot.recurrence = nil
                caveats.append("o macOS não deixa reinserir uma ocorrência na série, então ela volta como evento avulso")
            case .thisAndFuture:
                caveats.append("a série futura foi recriada como uma série nova")
                if case .count? = event.recurrence?.end { caveats.append("o número de repetições recomeça a contar desta ocorrência") }
            case .all:
                caveats.append("a série foi recriada como uma série nova")
            }
        }
        if event.attendees.contains(where: { !$0.isMe }) {
            caveats.append("os convidados não são restaurados e os cancelamentos já enviados não são desfeitos")
        }
        try await backend.delete(ref: event.ref, scope: scope, expectedModified: event.modified)
        push("apagar \"\(event.title)\"", .recreate(snapshot, originalID: event.id, caveat: caveats.isEmpty ? nil : caveats.joined(separator: "; ")))
    }

    public func undo() async throws -> UndoResult? {
        guard let entry = stack.popLast() else { return nil }
        do {
            switch entry.inverse {
            case .deleteCreated(let ref):
                try await backend.delete(ref: ref, scope: .all, expectedModified: nil)
            case .restore(let ref, let edit, let scope, _):
                _ = try await backend.update(ref: ref, edit: edit, scope: scope, expectedModified: nil)
            case .recreate(let draft, let originalID, _):
                let made = try await backend.create(draft)
                remap(from: originalID, to: made.id)
            }
        } catch let error as CalendarBackendError {
            if case .notFound = error { throw CalendarEditorError.undoTargetGone }
            stack.append(entry)
            throw error
        } catch {
            stack.append(entry)
            throw error
        }
        var caveat: String?
        switch entry.inverse {
        case .recreate(_, _, let note), .restore(_, _, _, let note):
            caveat = note.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
        default: break
        }
        return UndoResult(label: "Desfeito: \(entry.label)", caveat: caveat)
    }

    private func remap(from old: String, to new: String) {
        guard old != new else { return }
        stack = stack.map { entry in
            var entry = entry
            switch entry.inverse {
            case .deleteCreated(let ref) where ref.id == old:
                entry.inverse = .deleteCreated(EventRef(id: new, start: ref.start))
            case .restore(let ref, let edit, let scope, let caveat) where ref.id == old:
                entry.inverse = .restore(EventRef(id: new, start: ref.start), edit, scope, caveat: caveat)
            case .recreate(let draft, let originalID, let caveat) where originalID == old:
                entry.inverse = .recreate(draft, originalID: new, caveat: caveat)
            default: break
            }
            return entry
        }
    }
}
