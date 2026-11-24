import Foundation

/// Decides which calendar invitations become notch notices, and what they say.
public enum Invites {
    public static let horizon: TimeInterval = 14 * 86_400

    private static let weekdays = ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"]

    /// An invitation the user still has to answer: they are an invitee (not the organizer), their status is
    /// pending, and the event is ongoing or starts within the horizon.
    public static func isPending(_ event: CalEvent, now: Date) -> Bool {
        guard !event.declined, event.end > now, event.start <= now.addingTimeInterval(horizon) else { return false }
        guard let me = event.attendees.first(where: \.isMe) else { return false }
        return !me.isOrganizer && me.status == .pending
    }

    public static func pending(in events: [CalEvent], now: Date) -> [CalEvent] {
        events.filter { isPending($0, now: now) }.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
    }

    /// One invite per event, and one per recurring series (every occurrence of a series shares the UID and the answer);
    /// a one-off event also carries its start, so a UID reused at another time counts as new.
    public static func key(_ event: CalEvent) -> String {
        let id = event.iCalUID ?? event.id
        return event.isRecurring ? id : "\(id)|\(Int(event.start.timeIntervalSince1970))"
    }

    /// The organizer's name, or their address when EventKit gave no name; nil when the organizer is not among the attendees.
    public static func organizer(_ event: CalEvent) -> String? {
        guard let person = event.attendees.first(where: \.isOrganizer) else { return nil }
        let name = person.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        return person.email
    }

    /// "hoje às 12:30", "amanhã às 09:00" or "segunda, 30/11 às 14:00", in the given time zone.
    public static func whenLine(start: Date, now: Date, timeZone: TimeZone, allDay: Bool = false) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: start)).day ?? 0
        let day: String
        switch days {
        case 0: day = "hoje"
        case 1: day = "amanhã"
        default:
            let parts = calendar.dateComponents([.weekday, .day, .month], from: start)
            day = String(format: "%@, %02d/%02d", weekdays[(parts.weekday ?? 1) - 1], parts.day ?? 0, parts.month ?? 0)
        }
        if allDay { return "\(day), dia todo" }
        let time = calendar.dateComponents([.hour, .minute], from: start)
        return day + String(format: " às %02d:%02d", time.hour ?? 0, time.minute ?? 0)
    }

    /// Two lines: who invited, then when and where (the provider name when a link is detected, else the location).
    public static func preview(_ event: CalEvent, now: Date, timeZone: TimeZone, hideDetails: Bool = false) -> String {
        let who = hideDetails ? nil : organizer(event).map { "Convite de \($0)" }
        let first = who ?? "Convite"
        var second = whenLine(start: event.start, now: now, timeZone: timeZone, allDay: event.allDay)
        if hideDetails {
            // who invited, the provider and the place stay out of a notice that hides titles
        } else if let link = MeetingLinks.detect(event) {
            second += " · " + link.provider.name
        } else if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            second += " · " + location
        }
        return Notices.preview(first) + "\n" + Notices.preview(second)
    }

    public static func notice(for event: CalEvent, now: Date, timeZone: TimeZone = .current, hideTitles: Bool = false) -> Notice {
        Notice(
            sourceId: "invite:" + key(event), kind: .invite,
            title: MeetingLinks.displayTitle(event.title, hidden: hideTitles),
            preview: preview(event, now: now, timeZone: timeZone, hideDetails: hideTitles),
            time: now, target: .event(event.uid))
    }
}

extension Invites {
    public static let maxPerTick = 3
    public static let moreSourceId = "invites:more"

    /// At most `limit` invite notices; the rest fold into one "Mais N convites" card that opens the first of them.
    public static func notices(for events: [CalEvent], now: Date, timeZone: TimeZone = .current, hideTitles: Bool = false, limit: Int = maxPerTick) -> [Notice] {
        var cards = events.prefix(limit).map { notice(for: $0, now: now, timeZone: timeZone, hideTitles: hideTitles) }
        let rest = events.dropFirst(limit)
        if let first = rest.first {
            cards.append(Notice(
                sourceId: moreSourceId, kind: .invite, title: rest.count == 1 ? "Mais 1 convite" : "Mais \(rest.count) convites",
                preview: "Abra a Agenda para responder", time: now, target: .event(first.uid)))
        }
        return cards
    }
}

/// The invitations already announced, so a relaunch does not repeat them.
///
/// Nothing is announced until the ledger is seeded, and it seeds only when two reads at least `settleGap` apart
/// agree on what is pending. That way an empty first read (the calendar store had not synced yet) cannot turn
/// into a flood once the real list shows up: the later, fuller read disagrees with it and keeps learning.
public struct InviteLedger: Codable, Equatable, Sendable {
    public static let settleGap: TimeInterval = 60
    /// A series entry is renewed only when less than this is left, so an unchanged read leaves the ledger (and the file) alone.
    public static let renewBelow: TimeInterval = 7 * 86_400

    public struct Probe: Codable, Equatable, Sendable {
        public let keys: Set<String>
        public let at: Date
    }

    public private(set) var seeded = false
    /// Invite key to when the entry can go: the event's end, or a horizon after the last sighting for a series.
    public private(set) var seen: [String: Date] = [:]
    public private(set) var probe: Probe?

    public init() {}

    /// Invites that are pending now and were never seen (none while still learning). Forgets the ones that are over.
    public mutating func fresh(from events: [CalEvent], now: Date) -> [CalEvent] {
        seen = seen.filter { $0.value > now }
        let pending = Invites.pending(in: events, now: now)
        let keys = Set(pending.map(Invites.key))
        var news: [CalEvent] = []
        for event in pending {
            let key = Invites.key(event)
            if seeded, seen[key] == nil { news.append(event) }
            if !event.isRecurring {
                seen[key] = event.end
            } else if seen[key].map({ $0.timeIntervalSince(now) < Self.renewBelow }) ?? true {
                seen[key] = now.addingTimeInterval(Invites.horizon)
            }
        }
        if !seeded { learn(keys, now: now) }
        return news
    }

    private mutating func learn(_ keys: Set<String>, now: Date) {
        guard let last = probe else {
            probe = Probe(keys: keys, at: now)
            return
        }
        guard now.timeIntervalSince(last.at) >= Self.settleGap else { return }
        if last.keys == keys {
            seeded = true
            probe = nil
        } else {
            probe = Probe(keys: keys, at: now)
        }
    }

    public static func load(from url: URL) -> InviteLedger {
        guard let data = try? Data(contentsOf: url), let ledger = try? JSONDecoder().decode(InviteLedger.self, from: data) else { return InviteLedger() }
        return ledger
    }

    /// False when the file could not be written.
    @discardableResult
    public func save(to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
