import Foundation
@testable import WispCore

let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!

func makeCalendar(_ zone: TimeZone = saoPaulo) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
}

func stamp(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, zone: TimeZone = saoPaulo) -> Date {
    makeCalendar(zone).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

func makeEvent(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false, recurring: Bool = false, title: String = "E",
               calendarID: String = "c1", writable: Bool = true) -> CalEvent {
    CalEvent(id: id, calendarID: calendarID, title: title, start: start, end: end, allDay: allDay, isRecurring: recurring, writable: writable)
}

final class FakeCalendarBackend: CalendarBackend, @unchecked Sendable {
    var events: [CalEvent] = []
    var master: CalEvent?
    var created: [EventDraft] = []
    var updates: [(EventRef, EventEdit, RecurrenceScope)] = []
    var deletes: [(EventRef, RecurrenceScope)] = []
    var failNext: AgendaError?
    var access = AgendaAccess.granted
    var fetches: [(Date, Date)] = []

    func eventsAccess() -> AgendaAccess { access }
    func requestEventsAccess() async -> Bool { true }
    func calendars() async -> [CalCalendar] { [] }

    func events(from start: Date, to end: Date) async throws -> [CalEvent] {
        fetches.append((start, end))
        return events.filter { $0.start < end && $0.end > start }
    }

    func event(ref: EventRef) async throws -> CalEvent {
        if ref.start == nil, let master { return master }
        guard let found = events.first(where: { $0.id == ref.id && (ref.start == nil || $0.start == ref.start) }) else {
            throw AgendaError("não achei o evento \(ref.id)")
        }
        return found
    }

    func create(_ draft: EventDraft) async throws -> CalEvent {
        if let failNext { self.failNext = nil; throw failNext }
        created.append(draft)
        return CalEvent(id: "new\(created.count)", calendarID: draft.calendarID ?? "c1", title: draft.title, start: draft.start, end: draft.end,
                        allDay: draft.allDay, recurrence: draft.recurrence, isRecurring: draft.recurrence != nil)
    }

    func update(ref: EventRef, edit: EventEdit, scope: RecurrenceScope) async throws -> CalEvent {
        if let failNext { self.failNext = nil; throw failNext }
        updates.append((ref, edit, scope))
        var base = try await event(ref: ref)
        if let start = edit.start { base.start = start }
        if let end = edit.end { base.end = end }
        return base
    }

    func delete(ref: EventRef, scope: RecurrenceScope) async throws {
        if let failNext { self.failNext = nil; throw failNext }
        deletes.append((ref, scope))
    }

    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}
