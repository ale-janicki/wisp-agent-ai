import Foundation

public struct TimeSpan: Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public enum GridMath {
    public static let snapMinutes = 15
    public static let minimumMinutes = 15
    public static let defaultCreateMinutes = 60
    public static let minutesPerDay = 1_440

    public static func snap(_ minutes: Double, step: Int = snapMinutes) -> Int {
        Int((minutes / Double(step)).rounded()) * step
    }

    public static func minutes(atY y: Double, hourHeight: Double) -> Double {
        min(max(y / hourHeight * 60, 0), Double(minutesPerDay))
    }

    public static func yOffset(forMinutes minutes: Int, hourHeight: Double) -> Double {
        Double(minutes) / 60 * hourHeight
    }

    public static func createRange(fromY startY: Double, toY endY: Double, hourHeight: Double) -> (start: Int, end: Int) {
        let a = minutes(atY: min(startY, endY), hourHeight: hourHeight)
        let b = minutes(atY: max(startY, endY), hourHeight: hourHeight)
        var start = min(snapDown(a), minutesPerDay - minimumMinutes)
        var end = snap(b)
        if abs(endY - startY) < 4 {
            start = min(snapDown(a), minutesPerDay - defaultCreateMinutes)
            end = start + defaultCreateMinutes
        } else if end - start < minimumMinutes {
            end = start + minimumMinutes
        }
        return (start, min(end, minutesPerDay))
    }

    private static func snapDown(_ minutes: Double) -> Int {
        Int((minutes / Double(snapMinutes)).rounded(.down)) * snapMinutes
    }

    public static func minuteOfDay(_ date: Date, calendar: Calendar, roundingUp: Bool = false) -> Int {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0) + (roundingUp && (parts.second ?? 0) > 0 ? 1 : 0)
    }

    public static func date(onDayOf day: Date, minute: Int, calendar: Calendar) -> Date {
        let origin = calendar.startOfDay(for: day)
        let days = Int((Double(minute) / Double(minutesPerDay)).rounded(.down))
        let rest = minute - days * minutesPerDay
        guard let target = calendar.date(byAdding: .day, value: days, to: origin) else { return origin }
        if rest == 0 { return target }
        return calendar.date(bySettingHour: rest / 60, minute: rest % 60, second: 0, of: target) ?? target
    }

    private static func elapsedMinutes(from origin: Date, to date: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: origin), to: calendar.startOfDay(for: date)).day ?? 0
        return days * minutesPerDay + minuteOfDay(date, calendar: calendar)
    }

    public static func move(_ span: TimeSpan, deltaMinutes: Double, deltaDays: Int, calendar: Calendar) -> TimeSpan {
        let duration = span.end.timeIntervalSince(span.start)
        let startMinute = minuteOfDay(span.start, calendar: calendar)
        var minute = snap(Double(startMinute) + deltaMinutes)
        let durationMinutes = Int((duration / 60).rounded())
        if durationMinutes < minutesPerDay {
            minute = min(max(minute, 0), minutesPerDay - durationMinutes)
        }
        guard let day = calendar.date(byAdding: .day, value: deltaDays, to: calendar.startOfDay(for: span.start)) else { return span }
        let start = date(onDayOf: day, minute: minute, calendar: calendar)
        return TimeSpan(start: start, end: start.addingTimeInterval(duration))
    }

    public static func resizeEnd(_ span: TimeSpan, deltaMinutes: Double, calendar: Calendar) -> TimeSpan {
        let endMinute = elapsedMinutes(from: span.start, to: span.end, calendar: calendar)
        let startMinute = minuteOfDay(span.start, calendar: calendar)
        let snapped = max(snap(Double(endMinute) + deltaMinutes), startMinute + minimumMinutes)
        return TimeSpan(start: span.start, end: date(onDayOf: span.start, minute: snapped, calendar: calendar))
    }

    public static func resizeStart(_ span: TimeSpan, deltaMinutes: Double, calendar: Calendar) -> TimeSpan {
        let endMinute = elapsedMinutes(from: span.start, to: span.end, calendar: calendar)
        let startMinute = minuteOfDay(span.start, calendar: calendar)
        let snapped = min(max(snap(Double(startMinute) + deltaMinutes), 0), endMinute - minimumMinutes)
        return TimeSpan(start: date(onDayOf: span.start, minute: snapped, calendar: calendar), end: span.end)
    }

    public static func dayDelta(forTranslation x: Double, columnWidth: Double) -> Int {
        guard columnWidth > 0 else { return 0 }
        return Int((x / columnWidth).rounded())
    }

    public static func span(onDay day: Date, startMinute: Int, endMinute: Int, calendar: Calendar) -> TimeSpan? {
        TimeSpan(start: date(onDayOf: day, minute: startMinute, calendar: calendar), end: date(onDayOf: day, minute: endMinute, calendar: calendar))
    }
}
