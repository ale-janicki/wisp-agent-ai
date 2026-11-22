import Foundation

public struct EventPlacement: Equatable, Sendable {
    public let id: String
    public let column: Int
    public let columns: Int
    public let span: Int
    public let startMinute: Int
    public let endMinute: Int

    public init(id: String, column: Int, columns: Int, span: Int, startMinute: Int, endMinute: Int) {
        self.id = id
        self.column = column
        self.columns = columns
        self.span = span
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public var leadingFraction: Double { Double(column) / Double(columns) }
    public var widthFraction: Double { Double(span) / Double(columns) }
}

public struct DaySegment: Equatable, Sendable {
    public let id: String
    public let startMinute: Int
    public let endMinute: Int

    public init(id: String, startMinute: Int, endMinute: Int) {
        self.id = id
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

public enum EventLayout {
    public static let minimumVisibleMinutes = 20
    public static let minutesPerDay = 1_440

    public static func segment(of event: CalEvent, on day: Date, calendar: Calendar) -> DaySegment? {
        guard !event.allDay else { return nil }
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        guard event.start < dayEnd, event.end > dayStart || event.start == event.end && event.start >= dayStart else { return nil }
        let lower = max(event.start, dayStart), upper = min(event.end, dayEnd)
        let startMinute = Int((lower.timeIntervalSince(dayStart) / 60).rounded(.down))
        let rawEnd = Int((upper.timeIntervalSince(dayStart) / 60).rounded(.up))
        let endMinute = min(minutesPerDay, max(rawEnd, startMinute + minimumVisibleMinutes))
        return DaySegment(id: event.uid, startMinute: min(startMinute, minutesPerDay - 1), endMinute: endMinute)
    }

    public static func place(_ segments: [DaySegment]) -> [EventPlacement] {
        let ordered = segments.sorted {
            $0.startMinute != $1.startMinute ? $0.startMinute < $1.startMinute
                : $0.endMinute != $1.endMinute ? $0.endMinute > $1.endMinute : $0.id < $1.id
        }
        var placements: [EventPlacement] = []
        var cluster: [DaySegment] = []
        var clusterEnd = Int.min
        for segment in ordered {
            if segment.startMinute >= clusterEnd, !cluster.isEmpty {
                placements += place(cluster: cluster)
                cluster = []
                clusterEnd = Int.min
            }
            cluster.append(segment)
            clusterEnd = max(clusterEnd, segment.endMinute)
        }
        if !cluster.isEmpty { placements += place(cluster: cluster) }
        return placements
    }

    private static func place(cluster: [DaySegment]) -> [EventPlacement] {
        var columnEnds: [Int] = []
        var assigned: [(DaySegment, Int)] = []
        for segment in cluster {
            if let free = columnEnds.firstIndex(where: { $0 <= segment.startMinute }) {
                columnEnds[free] = segment.endMinute
                assigned.append((segment, free))
            } else {
                columnEnds.append(segment.endMinute)
                assigned.append((segment, columnEnds.count - 1))
            }
        }
        let columns = columnEnds.count
        return assigned.map { segment, column in
            var span = 1
            var next = column + 1
            while next < columns {
                let blocked = assigned.contains { other, otherColumn in
                    otherColumn == next && other.startMinute < segment.endMinute && other.endMinute > segment.startMinute
                }
                if blocked { break }
                span += 1
                next += 1
            }
            return EventPlacement(id: segment.id, column: column, columns: columns, span: span,
                                  startMinute: segment.startMinute, endMinute: segment.endMinute)
        }
    }

    public static func layout(_ events: [CalEvent], on day: Date, calendar: Calendar) -> [EventPlacement] {
        place(events.compactMap { segment(of: $0, on: day, calendar: calendar) })
    }
}

public struct EventIndex: Sendable {
    public private(set) var byDay: [Int: [CalEvent]] = [:]
    public let calendar: Calendar
    private let origin: Date

    public init(calendar: Calendar) {
        self.calendar = calendar
        origin = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
    }

    public func dayNumber(_ date: Date) -> Int {
        calendar.dateComponents([.day], from: origin, to: calendar.startOfDay(for: date)).day ?? 0
    }

    public func date(forDayNumber number: Int) -> Date {
        calendar.date(byAdding: .day, value: number, to: origin) ?? origin
    }

    public mutating func replace(range: Range<Int>, with events: [CalEvent]) {
        for day in range { byDay[day] = nil }
        for event in events {
            let first = dayNumber(event.start)
            let lastInstant = event.end > event.start ? event.end.addingTimeInterval(-1) : event.start
            let last = max(first, dayNumber(lastInstant))
            let low = max(first, range.lowerBound), high = min(last, range.upperBound - 1)
            guard low <= high else { continue }
            for day in low...high { byDay[day, default: []].append(event) }
        }
        for day in range {
            guard var list = byDay[day] else { continue }
            list.sort(by: Self.order)
            byDay[day] = list
        }
    }

    public mutating func removeAll() { byDay = [:] }

    public func events(onDay day: Int) -> [CalEvent] { byDay[day] ?? [] }

    public func events(on date: Date) -> [CalEvent] { events(onDay: dayNumber(date)) }

    public static func order(_ a: CalEvent, _ b: CalEvent) -> Bool {
        if a.allDay != b.allDay { return a.allDay }
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end > b.end }
        return a.uid < b.uid
    }
}
