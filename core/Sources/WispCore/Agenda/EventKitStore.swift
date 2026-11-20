import EventKit
import Foundation

public final class EventKitStore: AgendaStore, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func access(for kind: AgendaKind) -> AgendaAccess {
        switch EKEventStore.authorizationStatus(for: kind.entity) {
        case .fullAccess, .authorized: .granted
        case .notDetermined: .notDetermined
        case .writeOnly: .writeOnly
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    public func requestAccess(for kind: AgendaKind) async -> Bool {
        switch kind {
        case .events: (try? await store.requestFullAccessToEvents()) ?? false
        case .reminders: (try? await store.requestFullAccessToReminders()) ?? false
        }
    }

    public func calendars(for kind: AgendaKind) -> [AgendaCalendar] {
        store.calendars(for: kind.entity).map { Self.summary($0, kind: kind) }
    }

    public func events(from start: Date, to end: Date, calendarID: String?) throws -> [NativeEvent] {
        let scope = try calendarID.map { [try calendar($0)] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: scope)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.map(Self.event)
    }

    public func event(ref: EventRef) throws -> NativeEvent {
        Self.event(try ekEvent(ref))
    }

    public func createEvent(_ new: NewEvent) throws -> NativeEvent {
        let event = EKEvent(eventStore: store)
        event.title = new.title
        event.startDate = new.start
        event.endDate = new.end
        event.isAllDay = new.allDay
        event.location = new.location
        event.notes = new.notes
        if let id = new.calendarID {
            event.calendar = try calendar(id)
        } else if let fallback = store.defaultCalendarForNewEvents {
            event.calendar = fallback
        } else {
            throw AgendaError("não há calendário padrão para novos eventos; escolha um com --calendario")
        }
        try save(event, span: .thisEvent)
        return Self.event(event)
    }

    public func updateEvent(ref: EventRef, _ changes: EventChanges, wholeSeries: Bool) throws -> NativeEvent {
        let event = try ekEvent(ref)
        if let title = changes.title { event.title = title }
        if let allDay = changes.allDay { event.isAllDay = allDay }
        if let start = changes.start { event.startDate = start }
        if let end = changes.end { event.endDate = end }
        if let location = changes.location { event.location = location }
        if let notes = changes.notes { event.notes = notes }
        if let calendarID = changes.calendarID { event.calendar = try calendar(calendarID) }
        try save(event, span: wholeSeries ? .futureEvents : .thisEvent)
        return Self.event(event)
    }

    public func deleteEvent(ref: EventRef, wholeSeries: Bool) throws {
        let event = try ekEvent(ref)
        do {
            try store.remove(event, span: wholeSeries ? .futureEvents : .thisEvent, commit: true)
        } catch {
            throw AgendaError("não consegui apagar o evento: \(error.localizedDescription)")
        }
    }

    public func reminders(pendingOnly: Bool, listID: String?) async throws -> [AgendaReminder] {
        let scope = try listID.map { [try calendar($0)] }
        let predicate = pendingOnly
            ? store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: scope)
            : store.predicateForReminders(in: scope)
        let found: [AgendaReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.reminder))
            }
        }
        return found.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    public func createReminder(_ new: NewReminder) throws -> AgendaReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.title = new.title
        if let id = new.listID {
            reminder.calendar = try calendar(id)
        } else if let fallback = store.defaultCalendarForNewReminders() {
            reminder.calendar = fallback
        } else {
            throw AgendaError("não há lista padrão de lembretes; escolha uma com --lista")
        }
        if let due = new.due {
            let fields: Set<Calendar.Component> = new.dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: due)
        }
        try save(reminder)
        return Self.reminder(reminder)
    }

    public func completeReminder(id: String) throws -> AgendaReminder {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw AgendaError("não achei o lembrete \(id)")
        }
        reminder.isCompleted = true
        try save(reminder)
        return Self.reminder(reminder)
    }

    private func save(_ event: EKEvent, span: EKSpan) throws {
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            throw AgendaError("não consegui salvar o evento: \(error.localizedDescription)")
        }
    }

    private func save(_ reminder: EKReminder) throws {
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw AgendaError("não consegui salvar o lembrete: \(error.localizedDescription)")
        }
    }

    private func ekEvent(_ ref: EventRef) throws -> EKEvent {
        guard let start = ref.start else {
            guard let event = store.event(withIdentifier: ref.id) else { throw AgendaError("não achei o evento \(ref.id)") }
            return event
        }
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-86_400), end: start.addingTimeInterval(86_400), calendars: nil)
        let found = store.events(matching: predicate).first { $0.eventIdentifier == ref.id && abs($0.startDate.timeIntervalSince(start)) < 1 }
        guard let found else { throw AgendaError("não achei a ocorrência de \(ref.id) que começa nesse horário") }
        return found
    }

    private func calendar(_ id: String) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: id) else { throw AgendaError("não achei o calendário \(id)") }
        return calendar
    }

    private static func summary(_ calendar: EKCalendar, kind: AgendaKind) -> AgendaCalendar {
        AgendaCalendar(id: calendar.calendarIdentifier, title: calendar.title, source: calendar.source?.title ?? "",
                       kind: kind, writable: calendar.allowsContentModifications)
    }

    private static func event(_ event: EKEvent) -> NativeEvent {
        NativeEvent(id: event.eventIdentifier ?? "", calendar: event.calendar?.title ?? "", title: event.title ?? "",
                    start: event.startDate, end: event.endDate, allDay: event.isAllDay, location: nonEmpty(event.location),
                    notes: nonEmpty(event.notes),
                    attendees: (event.attendees ?? []).map { $0.name ?? $0.url.absoluteString },
                    recurring: event.hasRecurrenceRules)
    }

    private static func reminder(_ reminder: EKReminder) -> AgendaReminder {
        let parts = reminder.dueDateComponents
        return AgendaReminder(id: reminder.calendarItemIdentifier, list: reminder.calendar?.title ?? "", title: reminder.title ?? "",
                              due: parts.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) },
                              dueHasTime: parts?.hour != nil, completed: reminder.isCompleted,
                              completedAt: reminder.completionDate, notes: nonEmpty(reminder.notes))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

private extension AgendaKind {
    var entity: EKEntityType { self == .events ? .event : .reminder }
}
