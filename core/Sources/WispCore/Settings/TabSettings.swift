public enum TabSettingsBlock: String, CaseIterable, Sendable {
    case engine, model, permission, brain, agenda, meetings, macControl, integrations
}

public enum TabSettings {
    public static func blocks(forTab tab: String) -> [TabSettingsBlock] {
        switch tab {
        case "conversation": [.engine, .model, .permission]
        case "brain": [.brain]
        case "agenda": [.agenda]
        case "meetings": [.meetings]
        case "myMac": [.macControl]
        case "music": [.integrations]
        default: []
        }
    }

    public static func hasSettings(_ tab: String) -> Bool {
        !blocks(forTab: tab).isEmpty
    }

    public static func fullSection(forTab tab: String) -> String? {
        switch tab {
        case "conversation": "model"
        case "brain", "agenda", "meetings", "myMac": "general"
        case "music": "integrations"
        default: nil
        }
    }
}
