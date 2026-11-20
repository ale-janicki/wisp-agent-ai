import Foundation

public enum AgendaKind: String, Equatable, Sendable {
    case events = "eventos"
    case reminders = "lembretes"
}

public enum AgendaAccess: Equatable, Sendable {
    case granted
    case notDetermined
    case denied
    case restricted
    case writeOnly
}

public struct AgendaCalendar: Equatable, Sendable {
    public let id: String
    public let title: String
    public let source: String
    public let kind: AgendaKind
    public let writable: Bool

    public init(id: String, title: String, source: String, kind: AgendaKind, writable: Bool) {
        self.id = id
        self.title = title
        self.source = source
        self.kind = kind
        self.writable = writable
    }
}

public struct NativeEvent: Equatable, Sendable {
    public let id: String
    public let calendar: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let location: String?
    public let notes: String?
    public let attendees: [String]
    public let recurring: Bool

    public init(id: String, calendar: String, title: String, start: Date, end: Date, allDay: Bool,
                location: String? = nil, notes: String? = nil, attendees: [String] = [], recurring: Bool = false) {
        self.id = id
        self.calendar = calendar
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
        self.attendees = attendees
        self.recurring = recurring
    }
}

public struct EventRef: Equatable, Sendable {
    public let id: String
    public let start: Date?

    public init(id: String, start: Date? = nil) {
        self.id = id
        self.start = start
    }
}

public struct AgendaReminder: Equatable, Sendable {
    public let id: String
    public let list: String
    public let title: String
    public let due: Date?
    public let dueHasTime: Bool
    public let completed: Bool
    public let completedAt: Date?
    public let notes: String?

    public init(id: String, list: String, title: String, due: Date? = nil, dueHasTime: Bool = true,
                completed: Bool = false, completedAt: Date? = nil, notes: String? = nil) {
        self.id = id
        self.list = list
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
        self.completed = completed
        self.completedAt = completedAt
        self.notes = notes
    }
}

public struct NewEvent: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String?
    public var notes: String?
    public var calendarID: String?

    public init(title: String, start: Date, end: Date, allDay: Bool, location: String? = nil, notes: String? = nil,
                calendarID: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
        self.calendarID = calendarID
    }
}

public struct EventChanges: Equatable, Sendable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var allDay: Bool?
    public var location: String?
    public var notes: String?
    public var calendarID: String?

    public init(title: String? = nil, start: Date? = nil, end: Date? = nil, allDay: Bool? = nil, location: String? = nil,
                notes: String? = nil, calendarID: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
        self.calendarID = calendarID
    }

    public var isEmpty: Bool {
        title == nil && start == nil && end == nil && allDay == nil && location == nil && notes == nil && calendarID == nil
    }
}

public struct NewReminder: Equatable, Sendable {
    public var title: String
    public var due: Date?
    public var dueHasTime: Bool
    public var listID: String?

    public init(title: String, due: Date? = nil, dueHasTime: Bool = true, listID: String? = nil) {
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
        self.listID = listID
    }
}

public struct AgendaError: Error, Equatable, Sendable {
    public let message: String
    public let exitCode: Int32

    public init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    public static let permissionExitCode: Int32 = 2
    public static let needsConfirmationExitCode: Int32 = 3
}

public protocol AgendaStore: Sendable {
    func access(for kind: AgendaKind) -> AgendaAccess
    func requestAccess(for kind: AgendaKind) async -> Bool
    func calendars(for kind: AgendaKind) -> [AgendaCalendar]
    func events(from start: Date, to end: Date, calendarID: String?) throws -> [NativeEvent]
    func event(ref: EventRef) throws -> NativeEvent
    func createEvent(_ new: NewEvent) throws -> NativeEvent
    func updateEvent(ref: EventRef, _ changes: EventChanges, wholeSeries: Bool) throws -> NativeEvent
    func deleteEvent(ref: EventRef, wholeSeries: Bool) throws
    func reminders(pendingOnly: Bool, listID: String?) async throws -> [AgendaReminder]
    func createReminder(_ new: NewReminder) throws -> AgendaReminder
    func completeReminder(id: String) throws -> AgendaReminder
}
