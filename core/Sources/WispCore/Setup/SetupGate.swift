import Foundation

public enum SetupGate {
    /// A finished wizard never returns; a profile with no setup state is an existing install (adopted), not a fresh Mac.
    public static func shouldShowWizard(state: SetupState?, profileExists: Bool) -> Bool {
        if let state { return state.finishedAt == nil }
        return !profileExists
    }

    /// The first step, in wizard order, that the doctor reports failing and the user did not skip.
    public static func firstIncomplete(doctor: DoctorReport, state: SetupState) -> SetupStepID {
        let failing = Set(doctor.checks.filter { !$0.ok }.compactMap(\.step))
        return SetupStepID.allCases.first { step in
            step != .done && failing.contains(step.rawValue) && !state.skipped.contains(step.rawValue)
        } ?? .done
    }
}
