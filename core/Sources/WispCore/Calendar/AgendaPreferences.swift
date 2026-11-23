import Foundation

public enum CalendarViewMode: String, Codable, CaseIterable, Equatable, Sendable {
    case day, week, month, schedule
}

public struct AgendaPreferences: Codable, Equatable, Sendable {
    public var mode: CalendarViewMode = .week
    public var hiddenCalendars: Set<String> = []
    public var hiddenSources: Set<String> = []
    public var secondaryZones: [String] = []
    public var workingHours = WorkingHours.standard
    public var availabilityLanguage = AvailabilityLanguage.pt
    public var alertLeadMinutes = 1
    public var earlyAlertMinutes = 10
    public var meetingAlerts = true
    public var systemMeetingNotifications = false
    public var menuBarNext = true
    public var googleHintDismissed = false
    public var showSidebar = false
    public var hideTitlesInAlerts = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, hiddenCalendars, hiddenSources, secondaryZones, workingHours, availabilityLanguage, alertLeadMinutes, earlyAlertMinutes
        case meetingAlerts, systemMeetingNotifications, menuBarNext, googleHintDismissed, showSidebar, hideTitlesInAlerts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(CalendarViewMode.self, forKey: .mode)) ?? .week
        hiddenCalendars = (try? c.decodeIfPresent(Set<String>.self, forKey: .hiddenCalendars)) ?? []
        hiddenSources = (try? c.decodeIfPresent(Set<String>.self, forKey: .hiddenSources)) ?? []
        secondaryZones = (try? c.decodeIfPresent([String].self, forKey: .secondaryZones)) ?? []
        workingHours = (try? c.decodeIfPresent(WorkingHours.self, forKey: .workingHours)) ?? .standard
        availabilityLanguage = (try? c.decodeIfPresent(AvailabilityLanguage.self, forKey: .availabilityLanguage)) ?? .pt
        alertLeadMinutes = min(max((try? c.decodeIfPresent(Int.self, forKey: .alertLeadMinutes)) ?? 1, 0), 120)
        earlyAlertMinutes = min(max((try? c.decodeIfPresent(Int.self, forKey: .earlyAlertMinutes)) ?? 10, 0), 120)
        meetingAlerts = (try? c.decodeIfPresent(Bool.self, forKey: .meetingAlerts)) ?? true
        systemMeetingNotifications = (try? c.decodeIfPresent(Bool.self, forKey: .systemMeetingNotifications)) ?? false
        menuBarNext = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarNext)) ?? true
        googleHintDismissed = (try? c.decodeIfPresent(Bool.self, forKey: .googleHintDismissed)) ?? false
        showSidebar = (try? c.decodeIfPresent(Bool.self, forKey: .showSidebar)) ?? false
        hideTitlesInAlerts = (try? c.decodeIfPresent(Bool.self, forKey: .hideTitlesInAlerts)) ?? false
    }

    public func isVisible(_ calendar: CalCalendar) -> Bool {
        !hiddenCalendars.contains(calendar.id) && !hiddenSources.contains(calendar.sourceID)
    }

    public func visibleCalendarIDs(_ calendars: [CalCalendar]) -> Set<String> {
        Set(calendars.filter(isVisible).map(\.id))
    }
}
