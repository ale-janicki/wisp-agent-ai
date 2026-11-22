import Foundation

public enum SetupGate {
    public static func shouldShowWizard(state: SetupState?, profileExists: Bool) -> Bool {
        if let state { return state.finishedAt == nil }
        return !profileExists
    }
}
