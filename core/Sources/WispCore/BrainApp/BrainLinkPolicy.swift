import Foundation

public enum BrainLinkPolicy {
    public enum Decision: Sendable, Equatable {
        case open
        case reveal
        case refuse
    }

    public static func decide(_ url: URL) -> Decision {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto": .open
        case "file": .reveal
        default: .refuse
        }
    }
}
