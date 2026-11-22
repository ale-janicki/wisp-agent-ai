import Foundation

public struct QuickEvent: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var calendarName: String?
    public var location: String?
    public var hasDate: Bool
    public var hasTime: Bool
}

public enum CalendarDates {
    public static func allDayEnd(lastDay: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: lastDay).addingTimeInterval(86_399)
    }

    public static func lastDay(of event: CalEvent, calendar: Calendar) -> Date {
        let instant = event.end > event.start ? event.end.addingTimeInterval(-1) : event.start
        return calendar.startOfDay(for: max(instant, event.start))
    }
}

public enum QuickEventParser {
    private static let months: [String: Int] = [
        "janeiro": 1, "jan": 1, "january": 1, "fevereiro": 2, "fev": 2, "feb": 2, "february": 2,
        "marco": 3, "mar": 3, "march": 3, "abril": 4, "abr": 4, "apr": 4, "april": 4, "maio": 5, "mai": 5, "may": 5,
        "junho": 6, "jun": 6, "june": 6, "julho": 7, "jul": 7, "july": 7, "agosto": 8, "ago": 8, "aug": 8, "august": 8,
        "setembro": 9, "set": 9, "sep": 9, "sept": 9, "september": 9, "outubro": 10, "out": 10, "oct": 10, "october": 10,
        "novembro": 11, "nov": 11, "november": 11, "dezembro": 12, "dez": 12, "dec": 12, "december": 12,
    ]
    private static let monthNames = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")

    private static let weekdayNumbers: [String: Int] = [
        "domingo": 1, "sunday": 1, "sun": 1, "segunda": 2, "monday": 2, "mon": 2, "terca": 3, "tuesday": 3, "tues": 3, "tue": 3,
        "quarta": 4, "wednesday": 4, "wed": 4, "quinta": 5, "thursday": 5, "thurs": 5, "thu": 5, "sexta": 6, "friday": 6, "fri": 6,
        "sabado": 7, "saturday": 7, "sat": 7,
    ]
    private static let weekdayNames = weekdayNumbers.keys.sorted { $0.count > $1.count }.joined(separator: "|")

    private static let trailing: Set<String> = [
        "as", "a", "at", "on", "em", "no", "na", "de", "do", "da", "para", "for", "to", "in", "from", "das", "dos", "entre",
        "between", "por", "ate", "until", "e", "and", "-", "–", ",", "o", "the", "dia", "day", "@", "com-o",
    ]

    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func rx(_ pattern: String) -> NSRegularExpression {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[pattern] { return hit }
        let made = try! NSRegularExpression(pattern: pattern, options: [])
        cache[pattern] = made
        return made
    }

    private struct Text {
        var original: NSMutableString
        var folded: NSMutableString

        init(_ source: String) {
            let composed = source.precomposedStringWithCanonicalMapping
            let lowered = composed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            let same = lowered.utf16.count == composed.utf16.count
            original = NSMutableString(string: composed)
            folded = NSMutableString(string: same ? lowered : composed.lowercased())
        }

        var range: NSRange { NSRange(location: 0, length: folded.length) }

        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            QuickEventParser.rx(pattern).matches(in: folded as String, range: range)
        }

        func first(_ pattern: String, valid: (NSTextCheckingResult) -> Bool = { _ in true }) -> NSTextCheckingResult? {
            matches(pattern).first(where: valid)
        }

        func g(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let r = match.range(at: index)
            return r.location == NSNotFound ? nil : folded.substring(with: r)
        }

        func raw(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let r = match.range(at: index)
            return r.location == NSNotFound ? nil : original.substring(with: r)
        }

        func int(_ match: NSTextCheckingResult, _ index: Int) -> Int? { g(match, index).flatMap { Int($0) } }

        mutating func blank(_ range: NSRange) {
            guard range.location != NSNotFound else { return }
            let spaces = String(repeating: " ", count: range.length)
            original.replaceCharacters(in: range, with: spaces)
            folded.replaceCharacters(in: range, with: spaces)
        }
    }

    private struct Clock {
        var hour: Int
        var minute: Int
    }

    public static func parse(_ input: String, now: Date, calendar: Calendar, calendarNames: [String] = [], defaultMinutes: Int = 60) -> QuickEvent? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var text = Text(trimmed)
        var calendarName: String?
        var location: String?
        var allDay = false
        var startClock: Clock?
        var endClock: Clock?
        var endHadMeridiem = false
        var date: Date?
        var relativeStart: Date?
        var durationMinutes: Int?
        let today = calendar.startOfDay(for: now)

        calendarName = takeCalendar(&text, known: calendarNames)
        location = takeLocation(&text)

        if let m = text.first(#"\b(?:o\s+)?dia\s+(?:todo|inteiro)\b|\ball[\s-]?day\b|\bwhole\s+day\b"#) {
            allDay = true
            text.blank(m.range)
        }

        if let m = text.first(#"\b(?:em|daqui\s+a|in)\s+(\d+|uma?|an?|meia|half(?:\s+an?)?)\s*(horas?|hours?|hrs?|h|minutos?|minutes?|mins?|dias?|days?|semanas?|weeks?)\b"#) {
            let quantityWord = text.g(m, 1) ?? "1"
            let quantity: Double = Double(quantityWord) ?? (quantityWord.hasPrefix("meia") || quantityWord.hasPrefix("half") ? 0.5 : 1)
            let unit = text.g(m, 2) ?? "h"
            if unit.hasPrefix("m") {
                relativeStart = roundedToMinute(now.addingTimeInterval(quantity * 60), calendar: calendar)
            } else if unit.hasPrefix("h") {
                relativeStart = roundedToMinute(now.addingTimeInterval(quantity * 3_600), calendar: calendar)
            } else if unit.hasPrefix("d") {
                date = calendar.date(byAdding: .day, value: Int(quantity), to: today)
            } else {
                date = calendar.date(byAdding: .day, value: Int(quantity) * 7, to: today)
            }
            text.blank(m.range)
        }

        if let found = takeDuration(&text) { durationMinutes = found }

        if date == nil { date = takeNumericDate(&text, today: today, calendar: calendar) }

        if relativeStart == nil {
            if let range = takeRange(&text) {
                startClock = range.start
                endClock = range.end
                endHadMeridiem = range.endHadMeridiem
            } else if let single = takeClock(&text) {
                startClock = single
            }
        }

        if let m = text.first(#"\btonight\b"#) {
            date = date ?? today
            startClock = startClock ?? Clock(hour: 20, minute: 0)
            text.blank(m.range)
        }

        if date == nil { date = takeNamedDate(&text, today: today, calendar: calendar) }

        if startClock == nil, relativeStart == nil, date != nil, let part = takeDayPart(&text) { startClock = part }

        let title = cleaned(text)
        let hasDate = date != nil || relativeStart != nil
        let hasTime = startClock != nil || relativeStart != nil

        if allDay || (date != nil && startClock == nil && relativeStart == nil) {
            let day = date ?? today
            return QuickEvent(title: title, start: day, end: CalendarDates.allDayEnd(lastDay: day, calendar: calendar), allDay: true,
                              calendarName: calendarName, location: location, hasDate: true, hasTime: false)
        }
        var start: Date
        if let relativeStart {
            start = relativeStart
        } else if let startClock {
            start = at(startClock, on: date ?? today, calendar: calendar)
            if date == nil, start <= now { start = calendar.date(byAdding: .day, value: 1, to: start) ?? start }
        } else {
            start = nextQuarter(after: now, calendar: calendar)
        }
        var end: Date
        if let endClock {
            end = at(endClock, on: calendar.startOfDay(for: start), calendar: calendar)
            var firstTry = true
            while end <= start {
                if firstTry, !endHadMeridiem, endClock.hour < 12, let shifted = calendar.date(byAdding: .hour, value: 12, to: end), shifted > start {
                    end = shifted
                } else {
                    end = calendar.date(byAdding: .day, value: 1, to: end) ?? end.addingTimeInterval(86_400)
                }
                firstTry = false
            }
        } else {
            end = start.addingTimeInterval(Double(durationMinutes ?? defaultMinutes) * 60)
        }
        return QuickEvent(title: title, start: start, end: end, allDay: false, calendarName: calendarName, location: location,
                          hasDate: hasDate, hasTime: hasTime)
    }

    private static func roundedToMinute(_ date: Date, calendar: Calendar) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }

    private static func nextQuarter(after date: Date, calendar: Calendar) -> Date {
        let quarter = 900.0
        return Date(timeIntervalSinceReferenceDate: ((date.timeIntervalSinceReferenceDate / quarter).rounded(.down) + 1) * quarter)
    }

    private static func at(_ clock: Clock, on day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .minute, value: clock.hour * 60 + clock.minute, to: start) ?? start
    }

    private static func cleaned(_ text: Text) -> String {
        let collapsed = (text.original as String).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        var words = collapsed
        func isConnector(_ word: String) -> Bool {
            let key = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            return trailing.contains(key) || key.allSatisfy { "-–,;:@".contains($0) }
        }
        while let last = words.last, isConnector(last) { words.removeLast() }
        while let first = words.first, first.allSatisfy({ "-–,;:@".contains($0) }) { words.removeFirst() }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "-–,;: "))
    }

    private static func takeCalendar(_ text: inout Text, known: [String]) -> String? {
        if let m = text.first(#"(?<![\p{L}\p{N}])#([\p{L}\p{N}_-]+)"#) {
            let name = text.raw(m, 1)
            text.blank(m.range)
            return name
        }
        let pattern = #"(?:\b(?:no|na|em|in|on|to|para)\s+)?\b(?:calendario|calendar)\b\s*:?\s*(?:(?:do|da|de|chamado|named|called)\s+)?(.+?)(?=\s+@|$)"#
        guard let m = text.first(pattern) else { return nil }
        let restRange = m.range(at: 1)
        let rest = text.folded.substring(with: restRange)
        let foldedKnown = known.map { ($0, $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()) }
        let hit = foldedKnown
            .filter { rest == $0.1 || rest.hasPrefix($0.1 + " ") }
            .max { $0.1.count < $1.1.count }
        if let hit, (hit.1 as NSString).length <= restRange.length {
            let nameRange = NSRange(location: restRange.location, length: (hit.1 as NSString).length)
            let name = hit.0
            text.blank(NSRange(location: m.range.location, length: nameRange.location + nameRange.length - m.range.location))
            return name
        }
        let name = text.raw(m, 1)?.trimmingCharacters(in: .whitespaces)
        text.blank(m.range)
        return name
    }

    private static func takeLocation(_ text: inout Text) -> String? {
        guard let m = text.first(#"(?:(?<!\S)@(?!\s*\d{1,2}(?::\d{2})?\s*(?:am|pm|h)\b)|\b(?:local|location)\s*:)\s*(.+?)\s*$"#) else { return nil }
        let place = text.raw(m, 1)?.trimmingCharacters(in: .whitespaces)
        text.blank(m.range)
        return place?.isEmpty == false ? place : nil
    }

    private static func takeDuration(_ text: inout Text) -> Int? {
        let keywords = text.matches(#"\b(?:por|for|durante|lasting)\s+"#)
        let tails: [(String, (NSTextCheckingResult, Text) -> Int?)] = [
            (#"^(\d+)\s*h(?:ours?|oras?|rs?)?\s*(?:e|and)?\s*(\d{1,2})\s*(?:m|min\w*)\b"#, { m, t in (t.int(m, 1) ?? 0) * 60 + (t.int(m, 2) ?? 0) }),
            (#"^(\d+)h(\d{2})\b"#, { m, t in (t.int(m, 1) ?? 0) * 60 + (t.int(m, 2) ?? 0) }),
            (#"^(\d+(?:[.,]\d+)?)\s*(?:h|hr|hrs|hours?|horas?)\b"#, { m, t in
                Double((t.g(m, 1) ?? "").replacingOccurrences(of: ",", with: ".")).map { Int(($0 * 60).rounded()) }
            }),
            (#"^(\d+)\s*(?:m|min|mins|minutos?|minutes?)\b"#, { m, t in t.int(m, 1) }),
            (#"^(?:uma?|an?)\s+(?:hora|hour)\b"#, { _, _ in 60 }),
            (#"^(?:meia\s+hora|half\s+an?\s+hour|half\s+hour)\b"#, { _, _ in 30 }),
            (#"^(?:um|uma|a|an)\s+(?:minuto|minute)\b"#, { _, _ in 1 }),
        ]
        for keyword in keywords {
            let tailStart = keyword.range.location + keyword.range.length
            let tail = NSRange(location: tailStart, length: text.folded.length - tailStart)
            for (pattern, minutes) in tails {
                guard let m = rx(pattern).firstMatch(in: text.folded as String, range: tail),
                      m.range.location == tailStart, let value = minutes(m, text), value > 0 else { continue }
                text.blank(NSRange(location: keyword.range.location, length: m.range.location + m.range.length - keyword.range.location))
                return value
            }
        }
        return nil
    }

    private static func resolve(hour: Int, minute: Int, meridiem: String?) -> Clock? {
        guard minute >= 0, minute <= 59 else { return nil }
        if let meridiem {
            guard hour >= 1, hour <= 12 else { return nil }
            let base = hour % 12
            return Clock(hour: meridiem.hasPrefix("p") ? base + 12 : base, minute: minute)
        }
        guard hour >= 0, hour <= 24, !(hour == 24 && minute > 0) else { return nil }
        return Clock(hour: hour % 24, minute: minute)
    }

    private static func takeRange(_ text: inout Text) -> (start: Clock, end: Clock, endHadMeridiem: Bool)? {
        let atom = #"(\d{1,2})(?:[:h](\d{2})|h)?\s*(am|pm)?"#
        let pattern = #"(?<![\d:/.\-])(?<!\bdia\s)(?<!\bday\s)(?<!\bthe\s)(?<!\bon\s)(?:(das?|from|entre|between)\s+)?"# + atom
            + #"\s*(-|–|—|\ba\b|\bas\b|\bate\b|\bto\b|\band\b|\be\b|\buntil\b|\btill\b)\s*"# + atom + #"(?![\d:/])"#
        for m in text.matches(pattern) {
            let prefix = text.g(m, 1)
            let h1 = text.int(m, 2), m1 = text.int(m, 3) ?? 0, mer1 = text.g(m, 4)
            let separator = text.g(m, 5) ?? ""
            let h2 = text.int(m, 6), m2 = text.int(m, 7) ?? 0, mer2 = text.g(m, 8)
            guard let h1, let h2 else { continue }
            let marked = (text.g(m, 0) ?? "").contains { "h:".contains($0) } || mer1 != nil || mer2 != nil
            let dashed = ["-", "–", "—"].contains(separator)
            if !dashed, !marked, prefix == nil { continue }
            if !marked, prefix == nil, h1 < 6 { continue }
            var firstMeridiem = mer1
            if mer1 == nil, let mer2 {
                let opposite = mer2.hasPrefix("p") ? "am" : "pm"
                firstMeridiem = h1 % 12 <= h2 % 12 ? mer2 : opposite
            }
            guard let a = resolve(hour: h1, minute: m1, meridiem: firstMeridiem),
                  let b = resolve(hour: h2, minute: m2, meridiem: mer2) else { continue }
            text.blank(m.range)
            return (a, b, mer2 != nil)
        }
        return nil
    }

    private static func takeDayPart(_ text: inout Text) -> Clock? {
        guard let m = text.first(#"(?:\b(?:a|de|da|na|pela|in the|this)\s+)?\b(noite|tarde|manha|tonight|evening|afternoon|morning)\b"#) else { return nil }
        let word = text.g(m, 1) ?? ""
        text.blank(m.range)
        switch word {
        case "manha", "morning": return Clock(hour: 9, minute: 0)
        case "tarde", "afternoon": return Clock(hour: 15, minute: 0)
        default: return Clock(hour: 20, minute: 0)
        }
    }

    private static func takeClock(_ text: inout Text) -> Clock? {
        let patterns: [(String, (NSTextCheckingResult, Text) -> Clock?)] = [
            (#"(?:\b(?:as|at|@)\s+)?(?<![\d:/.])(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, { m, t in
                t.int(m, 1).flatMap { resolve(hour: $0, minute: t.int(m, 2) ?? 0, meridiem: t.g(m, 3)) }
            }),
            (#"(?:\b(?:as|at|@|a)\s+)?(?<![\d:/.])(\d{1,2})h(\d{2})?\b"#, { m, t in
                t.int(m, 1).flatMap { resolve(hour: $0, minute: t.int(m, 2) ?? 0, meridiem: nil) }
            }),
            (#"(?<![\d:/.])(\d{1,2}):(\d{2})\b"#, { m, t in
                t.int(m, 1).flatMap { resolve(hour: $0, minute: t.int(m, 2) ?? 0, meridiem: nil) }
            }),
            (#"\b(?:as|at|@)\s+(\d{1,2})\b(?![/:\d])"#, { m, t in
                guard let hour = t.int(m, 1) else { return nil }
                return resolve(hour: (1...6).contains(hour) ? hour + 12 : hour, minute: 0, meridiem: nil)
            }),
            (#"\b(meio[\s-]?dia|noon|midday|meia[\s-]?noite|midnight)\b"#, { m, t in
                let word = t.g(m, 1) ?? ""
                return Clock(hour: word.contains("noite") || word.contains("night") ? 0 : 12, minute: 0)
            }),
        ]
        for (pattern, build) in patterns {
            for m in text.matches(pattern) {
                guard let clock = build(m, text) else { continue }
                text.blank(m.range)
                return clock
            }
        }
        return nil
    }

    private static func date(year: Int?, month: Int, day: Int, today: Date, calendar: Calendar) -> Date? {
        let current = calendar.dateComponents([.year], from: today).year ?? 2026
        func make(_ y: Int) -> Date? {
            var parts = DateComponents(year: y, month: month, day: day)
            parts.calendar = calendar
            guard let built = calendar.date(from: parts), calendar.component(.day, from: built) == day,
                  calendar.component(.month, from: built) == month else { return nil }
            return calendar.startOfDay(for: built)
        }
        if let year { return make(year < 100 ? 2_000 + year : year) }
        guard let first = make(current) else { return nil }
        if first >= today { return first }
        return make(current + 1)
    }

    private static func takeNumericDate(_ text: inout Text, today: Date, calendar: Calendar) -> Date? {
        if let m = text.first(#"\b(\d{4})-(\d{2})-(\d{2})\b"#), let y = text.int(m, 1), let mo = text.int(m, 2), let d = text.int(m, 3),
           let found = date(year: y, month: mo, day: d, today: today, calendar: calendar) {
            text.blank(m.range)
            return found
        }
        for m in text.matches(#"(?<![\d/])(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?(?![\d/])"#) {
            guard let a = text.int(m, 1), let b = text.int(m, 2) else { continue }
            let year = text.int(m, 3)
            let (day, month) = (a > 12 && b <= 12) ? (a, b) : (b > 12 && a <= 12) ? (b, a) : (a, b)
            if let found = date(year: year, month: month, day: day, today: today, calendar: calendar) {
                text.blank(m.range)
                return found
            }
        }
        return nil
    }

    private static func takeNamedDate(_ text: inout Text, today: Date, calendar: Calendar) -> Date? {
        func plus(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: today) ?? today }
        if let m = text.first(#"\b(depois\s+de\s+amanha|day\s+after\s+tomorrow|amanha|tomorrow|tmrw|hoje|today)\b"#) {
            let word = text.g(m, 1) ?? ""
            text.blank(m.range)
            if word.hasPrefix("depois") || word.hasPrefix("day after") { return plus(2) }
            if word.hasPrefix("amanha") || word.hasPrefix("tomorrow") || word == "tmrw" { return plus(1) }
            return today
        }
        if let m = text.first(#"\b(?:semana\s+que\s+vem|proxima\s+semana|next\s+week)\b"#) {
            text.blank(m.range)
            return plus(7)
        }
        let weekdayPattern = #"\b(?:(proxima|proximo|next|this|esta|este)\s+)?("# + weekdayNames + #")(?:[\s-]feira)?\b(?:\s+(que\s+vem|next))?"#
        if let m = text.first(weekdayPattern), let name = text.g(m, 2), let target = weekdayNumbers[name] {
            let current = calendar.component(.weekday, from: today)
            var delta = (target - current + 7) % 7
            let modifier = text.g(m, 1) ?? ""
            let next = modifier.hasPrefix("prox") || modifier == "next" || text.g(m, 3) != nil
            if next, delta == 0 { delta = 7 }
            text.blank(m.range)
            return plus(delta)
        }
        if let m = text.first(#"(?<![\d/])(\d{1,2})(?:o|st|nd|rd|th|º)?\s*(?:de\s+)?("# + monthNames + #")\b(?:\s+(?:de\s+)?(\d{4}))?"#),
           let d = text.int(m, 1), let name = text.g(m, 2), let month = months[name],
           let found = date(year: text.int(m, 3), month: month, day: d, today: today, calendar: calendar) {
            text.blank(m.range)
            return found
        }
        if let m = text.first(#"\b("# + monthNames + #")\s+(\d{1,2})(?:st|nd|rd|th)?\b(?!\s*[:h]\d)"#),
           let name = text.g(m, 1), let month = months[name], let d = text.int(m, 2),
           let found = date(year: nil, month: month, day: d, today: today, calendar: calendar) {
            text.blank(m.range)
            return found
        }
        for pattern in [#"\b(?:dia|day)\s+(\d{1,2})\b"#, #"\b(?:on\s+)?the\s+(\d{1,2})(?:st|nd|rd|th)\b"#, #"\bon\s+(\d{1,2})(?:st|nd|rd|th)\b"#] {
            guard let m = text.first(pattern), let day = text.int(m, 1), (1...31).contains(day) else { continue }
            var probe = today
            for _ in 0..<14 {
                var parts = calendar.dateComponents([.year, .month], from: probe)
                parts.day = day
                if let built = calendar.date(from: parts), calendar.component(.day, from: built) == day, built >= today {
                    text.blank(m.range)
                    return calendar.startOfDay(for: built)
                }
                probe = calendar.date(byAdding: .month, value: 1, to: probe) ?? probe
            }
        }
        return nil
    }
}
