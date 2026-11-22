import Foundation

public enum MeetingProvider: String, Equatable, Sendable {
    case meet, zoom, teams, webex, slack, facetime

    public var name: String {
        switch self {
        case .meet: "Google Meet"
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .slack: "Slack"
        case .facetime: "FaceTime"
        }
    }
}

public struct MeetingLink: Equatable, Sendable {
    public let provider: MeetingProvider
    public let url: URL

    public init(provider: MeetingProvider, url: URL) {
        self.provider = provider
        self.url = url
    }
}

public enum MeetingLinks {
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?:https?|zoommtg|zoomus|msteams|webex|facetime)://[^\s<>"'\]\)]+"#, options: [.caseInsensitive])

    public static func provider(for url: URL) -> MeetingProvider? {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host()?.lowercased() ?? ""
        let path = url.path.lowercased()
        switch scheme {
        case "zoommtg", "zoomus": return .zoom
        case "msteams": return .teams
        case "webex": return .webex
        case "facetime": return .facetime
        case "http", "https": break
        default: return nil
        }
        if host == "meet.google.com" { return path.count > 1 || url.query != nil ? .meet : nil }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") || host.hasSuffix(".zoom.com") || host == "zoom.com" {
            return ["/j/", "/my/", "/s/", "/w/", "/wc/", "/join"].contains { path.hasPrefix($0) } ? .zoom : nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            return path.hasPrefix("/l/meetup-join") || path.hasPrefix("/meet") || path.hasPrefix("/meeting") ? .teams : nil
        }
        if host == "webex.com" || host.hasSuffix(".webex.com") {
            return path.count > 1 ? .webex : nil
        }
        if host == "slack.com" || host.hasSuffix(".slack.com") {
            return path.contains("/huddle/") || path.hasPrefix("/huddle") ? .slack : nil
        }
        if host == "facetime.apple.com" { return path.hasPrefix("/join") ? .facetime : nil }
        return nil
    }

    public static func links(in text: String) -> [MeetingLink] {
        let range = NSRange(text.startIndex..., in: text)
        return urlPattern.matches(in: text, range: range).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            let raw = String(text[found]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            guard let url = URL(string: raw), let provider = provider(for: url) else { return nil }
            return MeetingLink(provider: provider, url: url)
        }
    }

    private static func embedded(in text: String) -> MeetingLink? {
        for marker in ["https://", "http://"] {
            for part in text.components(separatedBy: marker).dropFirst() {
                if let found = links(in: marker + part).first { return found }
            }
        }
        return nil
    }

    public static func detect(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        if let url, let provider = provider(for: url) { return MeetingLink(provider: provider, url: url) }
        if let url, let nested = embedded(in: url.absoluteString) { return nested }
        for text in [location, notes] {
            if let text, let first = links(in: text).first { return first }
        }
        return nil
    }

    public static func detect(_ event: CalEvent) -> MeetingLink? {
        detect(url: event.url, location: event.location, notes: event.notes)
    }

    public static func next(in events: [CalEvent], now: Date) -> (event: CalEvent, link: MeetingLink)? {
        events
            .filter { !$0.allDay && !$0.declined && $0.end > now }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.uid < $1.uid }
            .lazy
            .compactMap { event in detect(event).map { (event, $0) } }
            .first
    }

    public static func countdown(to start: Date, end: Date, now: Date) -> String {
        if now >= start { return now < end ? "agora" : "terminou" }
        let seconds = Int(start.timeIntervalSince(now).rounded(.up))
        if seconds < 60 { return "em \(seconds) s" }
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "em \(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 24 { return rest == 0 ? "em \(hours) h" : "em \(hours) h \(rest) min" }
        return "em \(hours / 24) d"
    }

    public static let hiddenTitle = "Reunião"

    public static func displayTitle(_ title: String, hidden: Bool) -> String { hidden ? hiddenTitle : title }

    public static func menuBarTitle(title: String, start: Date, end: Date, now: Date, limit: Int = 22, hideTitle: Bool = false) -> String {
        let shown = displayTitle(title, hidden: hideTitle)
        let clipped = shown.count > limit ? String(shown.prefix(limit - 1)) + "…" : shown
        return "\(clipped) · \(countdown(to: start, end: end, now: now))"
    }

    public struct Alert: Equatable, Sendable {
        public let key: String
        public let title: String
        public let fireDate: Date
        public let start: Date
        public let url: URL
    }

    public static func alerts(for events: [CalEvent], now: Date, leadMinutes: Int, horizon: TimeInterval = 48 * 3_600, limit: Int = 40, hideTitles: Bool = false) -> [Alert] {
        let lead = TimeInterval(max(0, leadMinutes) * 60)
        return events
            .filter { !$0.allDay && !$0.declined && $0.start > now && $0.start.timeIntervalSince(now) <= horizon }
            .sorted { $0.start < $1.start }
            .compactMap { event -> Alert? in
                guard let link = detect(event) else { return nil }
                let fire = max(event.start.addingTimeInterval(-lead), now.addingTimeInterval(1))
                guard fire < event.start else { return nil }
                return Alert(key: event.uid, title: displayTitle(event.title, hidden: hideTitles), fireDate: fire, start: event.start, url: link.url)
            }
            .prefix(limit)
            .map { $0 }
    }
}
