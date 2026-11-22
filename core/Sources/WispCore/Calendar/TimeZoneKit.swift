import Foundation

public enum TimeZoneKit {
    public static let common: [String] = [
        "America/Sao_Paulo", "America/Argentina/Buenos_Aires", "America/Santiago", "America/Bogota", "America/Lima",
        "America/Mexico_City", "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
        "America/Toronto", "America/Vancouver", "Atlantic/Reykjavik", "Europe/Lisbon", "Europe/London", "Europe/Madrid",
        "Europe/Paris", "Europe/Berlin", "Europe/Rome", "Europe/Amsterdam", "Europe/Zurich", "Europe/Stockholm",
        "Europe/Athens", "Europe/Istanbul", "Europe/Moscow", "Africa/Cairo", "Africa/Johannesburg", "Africa/Lagos",
        "Asia/Dubai", "Asia/Kolkata", "Asia/Bangkok", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Shanghai",
        "Asia/Tokyo", "Asia/Seoul", "Australia/Sydney", "Pacific/Auckland", "UTC",
    ]

    public static func zone(_ identifier: String) -> TimeZone? { TimeZone(identifier: identifier) }

    public static func offsetLabel(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        if seconds == 0 { return "GMT" }
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "GMT\(sign)\(hours)" : "GMT\(sign)\(hours):" + String(format: "%02d", rest)
    }

    public static func city(_ zone: TimeZone) -> String {
        let last = zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    public static func label(_ zone: TimeZone, at date: Date) -> String {
        "\(city(zone)) (\(offsetLabel(zone, at: date)))"
    }

    public static func calendar(in zone: TimeZone, base: Calendar = .current) -> Calendar {
        var calendar = base
        calendar.timeZone = zone
        return calendar
    }

    public static func wallClock(_ date: Date, in zone: TimeZone) -> DateComponents {
        calendar(in: zone, base: Calendar(identifier: .gregorian))
            .dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    public static func reinterpret(_ date: Date, from source: TimeZone, to target: TimeZone) -> Date {
        let parts = wallClock(date, in: source)
        return calendar(in: target, base: Calendar(identifier: .gregorian)).date(from: parts) ?? date
    }

    public static func dayShift(of date: Date, from primary: TimeZone, to secondary: TimeZone) -> Int {
        let a = wallClock(date, in: primary), b = wallClock(date, in: secondary)
        guard let ad = a.day, let bd = b.day, let am = a.month, let bm = b.month, let ay = a.year, let by = b.year else { return 0 }
        let reference = calendar(in: .gmt, base: Calendar(identifier: .gregorian))
        guard let first = reference.date(from: DateComponents(year: ay, month: am, day: ad)),
              let second = reference.date(from: DateComponents(year: by, month: bm, day: bd)) else { return 0 }
        return reference.dateComponents([.day], from: first, to: second).day ?? 0
    }

    public static func clock(_ date: Date, in zone: TimeZone) -> String {
        let parts = wallClock(date, in: zone)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    public static func columnLabel(_ date: Date, primary: TimeZone, secondary: TimeZone) -> String {
        let shift = dayShift(of: date, from: primary, to: secondary)
        let base = clock(date, in: secondary)
        return shift == 0 ? base : "\(base) \(shift > 0 ? "+" : "-")\(abs(shift))"
    }

    public static func search(_ query: String, limit: Int = 12) -> [String] {
        let needle = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: " ", with: "_")
        let pool = common + TimeZone.knownTimeZoneIdentifiers.filter { !common.contains($0) }
        guard !needle.isEmpty else { return Array(common.prefix(limit)) }
        return Array(pool.filter { $0.localizedCaseInsensitiveContains(needle) }.prefix(limit))
    }
}
