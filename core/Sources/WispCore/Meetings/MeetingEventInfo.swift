import Foundation

public struct MeetingPerson: Codable, Equatable, Sendable {
    public var name: String
    public var email: String?

    public init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

public struct MeetingEventInfo: Codable, Equatable, Sendable {
    public var title: String
    public var calendar: String?
    public var organizer: MeetingPerson?
    public var attendees: [MeetingPerson]
    public var notes: String?
    public var url: String?

    public init(
        title: String, calendar: String? = nil, organizer: MeetingPerson? = nil, attendees: [MeetingPerson] = [],
        notes: String? = nil, url: String? = nil
    ) {
        self.title = title
        self.calendar = calendar
        self.organizer = organizer
        self.attendees = attendees
        self.notes = notes
        self.url = url
    }

    public init(event: CalEvent, calendarTitle: String?) {
        let others = event.attendees.filter { !$0.isMe }
        let organizer = event.attendees.first { $0.isOrganizer }
        self.init(
            title: event.title,
            calendar: calendarTitle,
            organizer: organizer.map { MeetingPerson(name: $0.name, email: $0.email) },
            attendees: others.map { MeetingPerson(name: $0.name, email: $0.email) },
            notes: Self.clean(event.notes),
            url: (MeetingLinks.detect(event)?.url ?? event.url)?.absoluteString
        )
    }

    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum MeetingEventMatcher {
    public static let lookahead: TimeInterval = 300

    public static func pick(events: [CalEvent], from start: Date, to end: Date) -> CalEvent? {
        let window = end > start ? end : start.addingTimeInterval(lookahead)
        let candidates = events.compactMap { event -> (event: CalEvent, overlap: TimeInterval)? in
            guard !event.allDay, !event.declined, event.end > event.start else { return nil }
            let overlap = min(event.end, window).timeIntervalSince(max(event.start, start))
            return overlap > 0 ? (event, overlap) : nil
        }
        return candidates.min { lhs, rhs in
            if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
            let leftPeople = !lhs.event.attendees.isEmpty, rightPeople = !rhs.event.attendees.isEmpty
            if leftPeople != rightPeople { return leftPeople }
            let leftLength = lhs.event.end.timeIntervalSince(lhs.event.start)
            let rightLength = rhs.event.end.timeIntervalSince(rhs.event.start)
            if leftLength != rightLength { return leftLength < rightLength }
            return lhs.event.id < rhs.event.id
        }?.event
    }
}
