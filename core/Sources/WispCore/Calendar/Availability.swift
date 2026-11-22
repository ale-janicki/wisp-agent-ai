import Foundation

public struct WorkingHours: Codable, Equatable, Sendable {
    public var weekdays: Set<Int>
    public var startMinute: Int
    public var endMinute: Int

    public init(weekdays: Set<Int> = [2, 3, 4, 5, 6], startMinute: Int = 9 * 60, endMinute: Int = 18 * 60) {
        self.weekdays = weekdays
        self.startMinute = min(max(startMinute, 0), 1_439)
        self.endMinute = min(max(endMinute, self.startMinute + 15), 1_440)
    }

    public static let standard = WorkingHours()
}

public enum AvailabilityLanguage: String, Codable, CaseIterable, Equatable, Sendable {
    case pt, en
}

public enum Availability {
    public static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.duration > 0 {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }

    public static func busyIntervals(from events: [CalEvent]) -> [DateInterval] {
        events.filter { !$0.allDay && !$0.declined && $0.busy && $0.end > $0.start }
            .map { DateInterval(start: $0.start, end: $0.end) }
    }

    public static func freeSlots(
        from first: Date, days: Int, busy: [DateInterval], hours: WorkingHours, calendar: Calendar, now: Date,
        minimumMinutes: Int = 30, bufferMinutes: Int = 0
    ) -> [DateInterval] {
        let blocked = merged(busy.map {
            DateInterval(start: $0.start.addingTimeInterval(-Double(bufferMinutes * 60)), end: $0.end.addingTimeInterval(Double(bufferMinutes * 60)))
        })
        var slots: [DateInterval] = []
        let origin = calendar.startOfDay(for: first)
        for offset in 0..<max(days, 0) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: origin),
                  hours.weekdays.contains(calendar.component(.weekday, from: day)) else { continue }
            let open = GridMath.date(onDayOf: day, minute: hours.startMinute, calendar: calendar)
            let close = GridMath.date(onDayOf: day, minute: hours.endMinute, calendar: calendar)
            var cursor = max(open, now)
            guard cursor < close else { continue }
            for block in blocked where block.end > cursor && block.start < close {
                if block.start > cursor { slots.append(DateInterval(start: cursor, end: block.start)) }
                cursor = max(cursor, block.end)
            }
            if cursor < close { slots.append(DateInterval(start: cursor, end: close)) }
        }
        return slots.filter { $0.duration >= Double(minimumMinutes * 60) }
    }

    public static func splitByDay(_ slots: [DateInterval], calendar: Calendar) -> [DateInterval] {
        var result: [DateInterval] = []
        for slot in slots where slot.duration > 0 {
            var cursor = slot.start
            while cursor < slot.end {
                let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor)) ?? slot.end
                let piece = min(nextDay, slot.end)
                result.append(DateInterval(start: cursor, end: piece))
                cursor = piece
            }
        }
        return result
    }

    private static let weekdaysPT = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]
    private static let weekdaysEN = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let monthsEN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    public static func time(_ date: Date, zone: TimeZone, language: AvailabilityLanguage) -> String {
        let parts = TimeZoneKit.wallClock(date, in: zone)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        switch language {
        case .pt: return String(format: "%02d:%02d", hour, minute)
        case .en:
            let twelve = hour % 12 == 0 ? 12 : hour % 12
            return String(format: "%d:%02d %@", twelve, minute, hour < 12 ? "AM" : "PM")
        }
    }

    public static func dayLabel(_ date: Date, zone: TimeZone, language: AvailabilityLanguage) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .day, .month], from: date)
        let weekday = (parts.weekday ?? 1) - 1, day = parts.day ?? 1, month = (parts.month ?? 1) - 1
        switch language {
        case .pt: return String(format: "%@, %02d/%02d", weekdaysPT[weekday], day, month + 1)
        case .en: return "\(weekdaysEN[weekday]), \(monthsEN[month]) \(day)"
        }
    }

    public static func text(_ slots: [DateInterval], zone: TimeZone, language: AvailabilityLanguage, at reference: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let pieces = splitByDay(merged(slots), calendar: calendar)
        guard !pieces.isEmpty else {
            return language == .pt ? "Sem horários livres no período." : "No free times in that period."
        }
        let zoneLabel = "\(zone.identifier), \(TimeZoneKit.offsetLabel(zone, at: reference))"
        var lines = [language == .pt ? "Tenho estes horários livres (\(zoneLabel)):" : "I'm free at these times (\(zoneLabel)):"]
        var order: [Date] = []
        var grouped: [Date: [String]] = [:]
        for piece in pieces {
            let day = calendar.startOfDay(for: piece.start)
            if grouped[day] == nil { order.append(day) }
            let end = piece.end == calendar.date(byAdding: .day, value: 1, to: day) ? "24:00" : time(piece.end, zone: zone, language: language)
            grouped[day, default: []].append("\(time(piece.start, zone: zone, language: language))–\(end)")
        }
        let joiner = language == .pt ? " e " : " and "
        for day in order {
            lines.append("• \(dayLabel(day, zone: zone, language: language)): \((grouped[day] ?? []).joined(separator: joiner))")
        }
        return lines.joined(separator: "\n")
    }
}
