import Foundation

public enum ReminderList {
    public static func parse(_ data: Data, timeZone: TimeZone) -> [AgendaReminder] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let dates = AgendaDates(timeZone: timeZone)
        return array.compactMap { object in
            guard let id = object["id"] as? String, let title = object["title"] as? String else { return nil }
            let parsed = (object["due"] as? String).flatMap(dates.parse)
            return AgendaReminder(id: id, list: object["list"] as? String ?? "", title: title, due: parsed?.date,
                                  dueHasTime: !(parsed?.dateOnly ?? false), completed: object["completed"] as? Bool ?? false,
                                  notes: object["notes"] as? String)
        }
    }

    public static func dueByToday(_ reminders: [AgendaReminder], now: Date, calendar: Calendar) -> [AgendaReminder] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return reminders
            .filter { !$0.completed && ($0.due.map { $0 < tomorrow } ?? false) }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    public static func isOverdue(_ reminder: AgendaReminder, now: Date, calendar: Calendar) -> Bool {
        guard let due = reminder.due else { return false }
        return reminder.dueHasTime ? due < now : due < calendar.startOfDay(for: now)
    }
}
