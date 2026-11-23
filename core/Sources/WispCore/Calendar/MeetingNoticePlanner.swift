import Foundation

/// Decides which meeting alerts become notch notices, and what they say.
public enum MeetingNoticePlanner {
    /// Alerts whose time has come and that were not posted yet, in fire order.
    public static func due(alerts: [MeetingLinks.Alert], posted: Set<String>, now: Date) -> [MeetingLinks.Alert] {
        alerts
            .filter { $0.fireDate <= now && !posted.contains($0.id) }
            .sorted { $0.fireDate != $1.fireDate ? $0.fireDate < $1.fireDate : $0.id < $1.id }
    }

    /// The new plan, plus alerts of the old plan that came due but were not posted yet. Replanning moves `now`,
    /// and a new plan drops an early alert whose time has passed, so without this it would be lost between ticks.
    public static func carryOver(old: [MeetingLinks.Alert], new: [MeetingLinks.Alert], posted: Set<String>, now: Date) -> [MeetingLinks.Alert] {
        let known = Set(new.map(\.id))
        let lost = old.filter { $0.fireDate <= now && $0.start > now && !posted.contains($0.id) && !known.contains($0.id) }
        return new + lost
    }

    /// Posted ids worth remembering: only those still in the plan, so the set cannot grow forever.
    public static func remembered(posted: Set<String>, alerts: [MeetingLinks.Alert]) -> Set<String> {
        posted.intersection(alerts.map(\.id))
    }

    public static func notice(for alert: MeetingLinks.Alert, now: Date) -> Notice {
        let minutes = max(0, Int((alert.start.timeIntervalSince(now) / 60).rounded()))
        return Notice(
            sourceId: "meeting:" + alert.id, kind: .meeting, title: alert.title,
            preview: minutes == 0 ? "Começando agora" : "Começa em \(minutes) min",
            time: now, target: .event(alert.key), tone: alert.early ? .normal : .warning)
    }
}
