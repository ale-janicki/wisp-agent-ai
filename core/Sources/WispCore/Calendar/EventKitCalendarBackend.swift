@preconcurrency import EventKit
import Foundation
import os

public final class EventKitCalendarBackend: CalendarBackend, @unchecked Sendable {
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).calendar.eventkit", qos: .userInitiated)
    private let log = Logger(subsystem: AppIdentity.bundleID, category: "calendar")

    public init() {}

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    public func eventsAccess() -> AgendaAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: .granted
        case .notDetermined: .notDetermined
        case .writeOnly: .writeOnly
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    public func requestEventsAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func calendars() async -> [CalCalendar] {
        (try? await run { [store] in
            store.calendars(for: .event).map(Self.calendar)
        }) ?? []
    }

    public func events(from start: Date, to end: Date) async throws -> [CalEvent] {
        let began = Date()
        let found = try await run { [store] in
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            return store.events(matching: predicate).map(Self.event)
        }
        log.info("fetch \(found.count) events in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
        return found
    }

    public func event(ref: EventRef) async throws -> CalEvent {
        try await run { [self] in Self.event(try ekEvent(ref)) }
    }

    public func create(_ draft: EventDraft) async throws -> CalEvent {
        try await run { [self] in
            let event = EKEvent(eventStore: store)
            if let id = draft.calendarID, let chosen = store.calendar(withIdentifier: id) {
                event.calendar = chosen
            } else if let fallback = store.defaultCalendarForNewEvents {
                event.calendar = fallback
            } else {
                throw AgendaError("não há calendário padrão para novos eventos")
            }
            guard event.calendar.allowsContentModifications else { throw AgendaError("\"\(event.calendar.title)\" é somente leitura") }
            event.title = draft.title
            event.isAllDay = draft.allDay
            if let id = draft.timeZoneID, !draft.allDay { event.timeZone = TimeZone(identifier: id) }
            event.startDate = draft.start
            event.endDate = draft.end
            event.location = draft.location
            event.url = draft.url
            event.notes = draft.notes
            event.alarms = draft.alarmOffsets.map { EKAlarm(relativeOffset: TimeInterval($0)) }
            if let rule = draft.recurrence { event.recurrenceRules = [Self.rule(rule)] }
            try save(event, span: .thisEvent)
            return Self.event(event)
        }
    }

    public func update(ref: EventRef, edit: EventEdit, scope: RecurrenceScope, expectedModified: Date?) async throws -> CalEvent {
        try await run { [self] in
            try verifyUnchanged(ref, expected: expectedModified)
            let target = scope == .all ? EventRef(id: ref.id) : ref
            let event = try ekEvent(target)
            guard event.calendar.allowsContentModifications else { throw AgendaError("\"\(event.calendar.title)\" é somente leitura") }
            if let title = edit.title { event.title = title }
            if let allDay = edit.allDay { event.isAllDay = allDay }
            if let id = edit.timeZoneID { event.timeZone = id.isEmpty ? nil : TimeZone(identifier: id) }
            if let start = edit.start { event.startDate = start }
            if let end = edit.end { event.endDate = end }
            if let location = edit.location { event.location = location.isEmpty ? nil : location }
            if let url = edit.url { event.url = url.isEmpty ? nil : URL(string: url) }
            if let notes = edit.notes { event.notes = notes.isEmpty ? nil : notes }
            if let id = edit.calendarID {
                guard let chosen = store.calendar(withIdentifier: id) else { throw AgendaError("não achei o calendário \(id)") }
                event.calendar = chosen
            }
            if let offsets = edit.alarmOffsets { event.alarms = offsets.map { EKAlarm(relativeOffset: TimeInterval($0)) } }
            if scope != .thisOnly {
                switch edit.recurrence {
                case .keep: break
                case .remove: event.recurrenceRules = nil
                case .set(let rule): event.recurrenceRules = [Self.rule(rule)]
                }
            }
            try save(event, span: scope == .thisOnly ? .thisEvent : .futureEvents)
            return Self.event(event)
        }
    }

    public func delete(ref: EventRef, scope: RecurrenceScope, expectedModified: Date?) async throws {
        try await run { [self] in
            try verifyUnchanged(ref, expected: expectedModified)
            let event = try ekEvent(scope == .all ? EventRef(id: ref.id) : ref)
            guard event.calendar.allowsContentModifications else { throw AgendaError("\"\(event.calendar.title)\" é somente leitura") }
            do {
                try store.remove(event, span: scope == .thisOnly ? .thisEvent : .futureEvents, commit: true)
            } catch {
                throw AgendaError("não consegui apagar o evento: \(error.localizedDescription)")
            }
        }
    }

    public func changes() -> AsyncStream<Void> {
        let store = store
        return AsyncStream { continuation in
            nonisolated(unsafe) let token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { _ in
                continuation.yield()
            }
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token) }
        }
    }

    private func save(_ event: EKEvent, span: EKSpan) throws {
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            throw AgendaError("não consegui salvar o evento: \(error.localizedDescription)")
        }
    }

    private func verifyUnchanged(_ ref: EventRef, expected: Date?) throws {
        guard let expected else { return }
        let probe = try ekEvent(ref)
        guard probe.refresh() else { throw CalendarBackendError.notFound(ref.id) }
        if let current = probe.lastModifiedDate, abs(current.timeIntervalSince(expected)) > 0.5 {
            throw CalendarBackendError.modifiedExternally(probe.title ?? "Evento")
        }
    }

    private func ekEvent(_ ref: EventRef) throws -> EKEvent {
        guard let start = ref.start else {
            guard let found = store.event(withIdentifier: ref.id) else { throw CalendarBackendError.notFound(ref.id) }
            return found
        }
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-86_400), end: start.addingTimeInterval(86_400), calendars: nil)
        guard let found = store.events(matching: predicate).first(where: { $0.eventIdentifier == ref.id && abs($0.startDate.timeIntervalSince(start)) < 1 }) else {
            throw CalendarBackendError.notFound(ref.id)
        }
        return found
    }

    private static func rule(_ recurrence: CalRecurrence) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency = switch recurrence.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
        let end: EKRecurrenceEnd? = switch recurrence.end {
        case .never: nil
        case .count(let count): EKRecurrenceEnd(occurrenceCount: count)
        case .until(let date): EKRecurrenceEnd(end: date)
        }
        func numbers(_ list: [Int]) -> [NSNumber]? { list.isEmpty ? nil : list.map { NSNumber(value: $0) } }
        let days = recurrence.daysOfWeek.compactMap { day in
            EKWeekday(rawValue: day.weekday).map { EKRecurrenceDayOfWeek(dayOfTheWeek: $0, weekNumber: day.weekNumber) }
        }
        if !recurrence.hasDetail { return EKRecurrenceRule(recurrenceWith: frequency, interval: recurrence.interval, end: end) }
        return EKRecurrenceRule(
            recurrenceWith: frequency, interval: recurrence.interval, daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: numbers(recurrence.daysOfMonth), monthsOfTheYear: numbers(recurrence.monthsOfYear),
            weeksOfTheYear: numbers(recurrence.weeksOfYear), daysOfTheYear: numbers(recurrence.daysOfYear),
            setPositions: numbers(recurrence.setPositions), end: end)
    }

    private static func recurrence(_ rule: EKRecurrenceRule) -> CalRecurrence? {
        let frequency: RecurrenceFrequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return nil
        }
        let end: RecurrenceEnd
        if let finish = rule.recurrenceEnd {
            end = finish.endDate.map(RecurrenceEnd.until) ?? .count(finish.occurrenceCount)
        } else {
            end = .never
        }
        func list(_ numbers: [NSNumber]?) -> [Int] { (numbers ?? []).map(\.intValue) }
        return CalRecurrence(
            frequency: frequency, interval: rule.interval, end: end,
            daysOfWeek: (rule.daysOfTheWeek ?? []).map { RecurrenceDay(weekday: $0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber) },
            daysOfMonth: list(rule.daysOfTheMonth), monthsOfYear: list(rule.monthsOfTheYear), weeksOfYear: list(rule.weeksOfTheYear),
            daysOfYear: list(rule.daysOfTheYear), setPositions: list(rule.setPositions))
    }

    private static func calendar(_ calendar: EKCalendar) -> CalCalendar {
        let kind: CalendarSourceKind = switch calendar.source?.sourceType {
        case .local: .local
        case .exchange: .exchange
        case .calDAV: .caldav
        case .mobileMe: .iCloud
        case .subscribed: .subscribed
        case .birthdays: .birthdays
        default: .other
        }
        return CalCalendar(
            id: calendar.calendarIdentifier, title: calendar.title, sourceID: calendar.source?.sourceIdentifier ?? "",
            sourceTitle: calendar.source?.title ?? "", sourceKind: kind, colorHex: hex(calendar.cgColor),
            writable: calendar.allowsContentModifications)
    }

    private static func hex(_ color: CGColor?) -> UInt32 {
        guard let color, let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = srgb.components, c.count >= 3 else { return 0x60A5FA }
        func byte(_ v: CGFloat) -> UInt32 { UInt32(min(max(v, 0), 1) * 255) }
        return byte(c[0]) << 16 | byte(c[1]) << 8 | byte(c[2])
    }

    private static func event(_ event: EKEvent) -> CalEvent {
        let me = event.attendees?.first(where: \.isCurrentUser)
        let attendees = (event.attendees ?? []).map { person -> CalAttendee in
            let status: AttendeeStatus = switch person.participantStatus {
            case .accepted: .accepted
            case .declined: .declined
            case .tentative: .tentative
            default: .pending
            }
            let address = person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return CalAttendee(name: person.name ?? address, email: address.contains("@") ? address : nil, status: status,
                               isOrganizer: person.isCurrentUser ? event.organizer?.isCurrentUser == true : person == event.organizer,
                               isMe: person.isCurrentUser)
        }
        return CalEvent(
            id: event.eventIdentifier ?? "", calendarID: event.calendar?.calendarIdentifier ?? "", title: event.title ?? "",
            start: event.startDate, end: event.endDate, allDay: event.isAllDay, timeZoneID: event.timeZone?.identifier,
            location: nonEmpty(event.location), url: event.url, notes: nonEmpty(event.notes), attendees: attendees,
            alarmOffsets: (event.alarms ?? []).compactMap { $0.absoluteDate == nil ? Int($0.relativeOffset) : nil },
            recurrence: event.recurrenceRules?.first.flatMap(recurrence), isRecurring: event.hasRecurrenceRules,
            writable: event.calendar?.allowsContentModifications ?? false, busy: event.availability != .free,
            declined: me?.participantStatus == .declined, modified: event.lastModifiedDate)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
