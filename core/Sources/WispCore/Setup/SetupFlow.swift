import Foundation

/// The wizard's decisions that need no UI, so they can be tested.
public enum SetupFlow {
    /// The Command Line Tools are in: `wisp setup system` can go on and install Claude Code itself.
    /// Claude is not part of the condition, because that step is what installs it.
    public static func shouldRerunSystem(doctor: DoctorReport) -> Bool {
        doctor.checks.first { $0.id == "clt" }?.ok == true
    }

    /// Where the wizard opens. A doctor that could not be read never means "all done".
    public static func openingStep(doctor: DoctorReport?, state: SetupState) -> SetupStepID {
        guard let doctor else { return .system }
        return SetupGate.firstIncomplete(doctor: doctor, state: state)
    }

    /// What to write after a step. An existing install (re-run, or a profile already there) keeps or gets a
    /// `finishedAt`, so closing the window never makes the gate show the wizard again.
    public static func persisted(_ state: SetupState?, existingInstall: Bool, now: Date) -> SetupState {
        var next = state ?? SetupState()
        if existingInstall, next.finishedAt == nil { next.finishedAt = now }
        return next
    }
}
