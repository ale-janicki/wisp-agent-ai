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

    public static func move(_ span: TimeSpan, deltaMinutes: Double, deltaDays: Int, calendar: Calendar) -> TimeSpan {
        let duration = span.end.timeIntervalSince(span.start)
        let originDay = calendar.startOfDay(for: span.start)
        let startMinute = span.start.timeIntervalSince(originDay) / 60
        var minute = snap(startMinute + deltaMinutes)
        let durationMinutes = Int((duration / 60).rounded())
        if durationMinutes < minutesPerDay {
            minute = min(max(minute, 0), minutesPerDay - durationMinutes)
        }
        guard let day = calendar.date(byAdding: .day, value: deltaDays, to: originDay),
              let start = calendar.date(byAdding: .minute, value: minute, to: day) else { return span }
        return TimeSpan(start: start, end: start.addingTimeInterval(duration))
    }

    public static func resizeEnd(_ span: TimeSpan, deltaMinutes: Double, calendar: Calendar) -> TimeSpan {
        let startDay = calendar.startOfDay(for: span.start)
        let endMinute = span.end.timeIntervalSince(startDay) / 60 + deltaMinutes
        var snapped = snap(endMinute)
        let startMinute = Int((span.start.timeIntervalSince(startDay) / 60).rounded())
        snapped = max(snapped, startMinute + minimumMinutes)
        guard let end = calendar.date(byAdding: .minute, value: snapped, to: startDay) else { return span }
        return TimeSpan(start: span.start, end: end)
    }

    public static func resizeStart(_ span: TimeSpan, deltaMinutes: Double, calendar: Calendar) -> TimeSpan {
        let startDay = calendar.startOfDay(for: span.start)
        let startMinute = span.start.timeIntervalSince(startDay) / 60 + deltaMinutes
        let endMinute = Int((span.end.timeIntervalSince(startDay) / 60).rounded())
        let snapped = min(max(snap(startMinute), 0), endMinute - minimumMinutes)
        guard let start = calendar.date(byAdding: .minute, value: snapped, to: startDay) else { return span }
        return TimeSpan(start: start, end: span.end)
    }

    public static func dayDelta(forTranslation x: Double, columnWidth: Double) -> Int {
        guard columnWidth > 0 else { return 0 }
        return Int((x / columnWidth).rounded())
    }

    public static func span(onDay day: Date, startMinute: Int, endMinute: Int, calendar: Calendar) -> TimeSpan? {
        let origin = calendar.startOfDay(for: day)
        guard let start = calendar.date(byAdding: .minute, value: startMinute, to: origin),
              let end = calendar.date(byAdding: .minute, value: endMinute, to: origin) else { return nil }
        return TimeSpan(start: start, end: end)
    }
}
