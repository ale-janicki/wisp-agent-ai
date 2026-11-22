import Foundation

public enum CalendarSourceKind: String, Codable, Equatable, Sendable {
    case local, iCloud, exchange, caldav, subscribed, birthdays, other
}

public struct CalCalendar: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let sourceID: String
    public let sourceTitle: String
    public let sourceKind: CalendarSourceKind
    public let colorHex: UInt32
    public let writable: Bool

    public init(id: String, title: String, sourceID: String, sourceTitle: String, sourceKind: CalendarSourceKind,
                colorHex: UInt32, writable: Bool) {
        self.id = id
        self.title = title
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.sourceKind = sourceKind
        self.colorHex = colorHex
        self.writable = writable
    }
}

public enum AttendeeStatus: String, Equatable, Sendable {
    case accepted, declined, tentative, pending
}

public struct CalAttendee: Equatable, Sendable {
    public let name: String
    public let email: String?
    public let status: AttendeeStatus
    public let isOrganizer: Bool
    public let isMe: Bool

    public init(name: String, email: String? = nil, status: AttendeeStatus = .pending, isOrganizer: Bool = false, isMe: Bool = false) {
        self.name = name
        self.email = email
        self.status = status
        self.isOrganizer = isOrganizer
        self.isMe = isMe
    }
}

public enum RecurrenceFrequency: String, Codable, CaseIterable, Equatable, Sendable {
    case daily, weekly, monthly, yearly
}

public enum RecurrenceEnd: Codable, Equatable, Sendable {
    case never
    case count(Int)
    case until(Date)
}

public struct CalRecurrence: Codable, Equatable, Sendable {
    public var frequency: RecurrenceFrequency
    public var interval: Int
    public var end: RecurrenceEnd

    public init(frequency: RecurrenceFrequency, interval: Int = 1, end: RecurrenceEnd = .never) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.end = end
    }
}

public struct CalEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public var calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var timeZoneID: String?
    public var location: String?
    public var url: URL?
    public var notes: String?
    public var attendees: [CalAttendee]
    public var alarmOffsets: [Int]
    public var recurrence: CalRecurrence?
    public var isRecurring: Bool
    public var writable: Bool
    public var busy: Bool
    public var declined: Bool

    public init(
        id: String, calendarID: String, title: String, start: Date, end: Date, allDay: Bool = false, timeZoneID: String? = nil,
        location: String? = nil, url: URL? = nil, notes: String? = nil, attendees: [CalAttendee] = [], alarmOffsets: [Int] = [],
        recurrence: CalRecurrence? = nil, isRecurring: Bool = false, writable: Bool = true, busy: Bool = true, declined: Bool = false
    ) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.timeZoneID = timeZoneID
        self.location = location
        self.url = url
        self.notes = notes
        self.attendees = attendees
        self.alarmOffsets = alarmOffsets
        self.recurrence = recurrence
        self.isRecurring = isRecurring
        self.writable = writable
        self.busy = busy
        self.declined = declined
    }

    public var uid: String { isRecurring ? "\(id)@\(Int(start.timeIntervalSince1970))" : id }
    public var ref: EventRef { EventRef(id: id, start: isRecurring ? start : nil) }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var timeZone: TimeZone? { timeZoneID.flatMap(TimeZone.init(identifier:)) }
}

public enum RecurrenceScope: String, CaseIterable, Equatable, Sendable {
    case thisOnly, thisAndFuture, all

    public var label: String {
        switch self {
        case .thisOnly: "Só este"
        case .thisAndFuture: "Este e os próximos"
        case .all: "Todos"
        }
    }

    public static func choices(for event: CalEvent) -> [RecurrenceScope] {
        event.isRecurring ? allCases : []
    }

    public static func needsChoice(for event: CalEvent) -> Bool { event.isRecurring }

    public static func resolved(_ chosen: RecurrenceScope?, for event: CalEvent) -> RecurrenceScope {
        event.isRecurring ? (chosen ?? .thisOnly) : .thisOnly
    }
}

public struct EventDraft: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var calendarID: String?
    public var timeZoneID: String?
    public var location: String?
    public var url: URL?
    public var notes: String?
    public var alarmOffsets: [Int]
    public var recurrence: CalRecurrence?

    public init(title: String, start: Date, end: Date, allDay: Bool = false, calendarID: String? = nil, timeZoneID: String? = nil,
                location: String? = nil, url: URL? = nil, notes: String? = nil, alarmOffsets: [Int] = [], recurrence: CalRecurrence? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendarID = calendarID
        self.timeZoneID = timeZoneID
        self.location = location
        self.url = url
        self.notes = notes
        self.alarmOffsets = alarmOffsets
        self.recurrence = recurrence
    }

    public init(_ event: CalEvent) {
        self.init(title: event.title, start: event.start, end: event.end, allDay: event.allDay, calendarID: event.calendarID,
                  timeZoneID: event.timeZoneID, location: event.location, url: event.url, notes: event.notes,
                  alarmOffsets: event.alarmOffsets, recurrence: event.recurrence)
    }
}

public enum RecurrenceChange: Equatable, Sendable {
    case keep
    case set(CalRecurrence)
    case remove
}

public struct EventEdit: Equatable, Sendable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var allDay: Bool?
    public var calendarID: String?
    public var timeZoneID: String?
    public var location: String?
    public var url: String?
    public var notes: String?
    public var alarmOffsets: [Int]?
    public var recurrence: RecurrenceChange

    public init(title: String? = nil, start: Date? = nil, end: Date? = nil, allDay: Bool? = nil, calendarID: String? = nil,
                timeZoneID: String? = nil, location: String? = nil, url: String? = nil, notes: String? = nil,
                alarmOffsets: [Int]? = nil, recurrence: RecurrenceChange = .keep) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendarID = calendarID
        self.timeZoneID = timeZoneID
        self.location = location
        self.url = url
        self.notes = notes
        self.alarmOffsets = alarmOffsets
        self.recurrence = recurrence
    }

    public var isEmpty: Bool { self == EventEdit() }

    public static func restoring(_ event: CalEvent) -> EventEdit {
        EventEdit(title: event.title, start: event.start, end: event.end, allDay: event.allDay, calendarID: event.calendarID,
                  timeZoneID: event.timeZoneID ?? "", location: event.location ?? "", url: event.url?.absoluteString ?? "",
                  notes: event.notes ?? "", alarmOffsets: event.alarmOffsets,
                  recurrence: event.recurrence.map(RecurrenceChange.set) ?? .remove)
    }
}

public protocol CalendarBackend: Sendable {
    func eventsAccess() -> AgendaAccess
    func requestEventsAccess() async -> Bool
    func calendars() async -> [CalCalendar]
    func events(from start: Date, to end: Date) async throws -> [CalEvent]
    func event(ref: EventRef) async throws -> CalEvent
    func create(_ draft: EventDraft) async throws -> CalEvent
    func update(ref: EventRef, edit: EventEdit, scope: RecurrenceScope) async throws -> CalEvent
    func delete(ref: EventRef, scope: RecurrenceScope) async throws
    func changes() -> AsyncStream<Void>
}
