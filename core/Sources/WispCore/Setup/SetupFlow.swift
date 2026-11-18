import Foundation

/// The wizard's decisions that need no UI, so they can be tested.
public enum SetupFlow {
    /// What a `needs_user` from the system step is waiting for: Apple's Command Line Tools, or the Homebrew installer.
    public enum SystemWait: Equatable, Sendable {
        case commandLineTools, homebrew

        /// The doctor checks the poll reads for this wait.
        public var doctorChecks: String {
            switch self {
            case .commandLineTools: "clt,claude"
            case .homebrew: "homebrew"
            }
        }
    }

    /// The step names what it waits for in `data.waiting`; a report without it is the Command Line Tools wait.
    public static func systemWait(_ report: SetupReport) -> SystemWait {
        report.data["waiting"] == "homebrew" ? .homebrew : .commandLineTools
    }

    /// The wait is over and `wisp setup system` can run again. For the Command Line Tools, Claude is not part of the
    /// condition, because that step is what installs it. For Homebrew, brew itself must be there: re-running earlier
    /// would download and open the installer again.
    public static func shouldRerunSystem(after wait: SystemWait, doctor: DoctorReport) -> Bool {
        let id = wait == .homebrew ? "homebrew" : "clt"
        return doctor.checks.first { $0.id == id }?.ok == true
    }

    /// The poll's end. A run the user started gets a fresh limit; the automatic re-run after a wait keeps the one it had.
    public static func pollDeadline(current: Date?, automaticRerun: Bool, now: Date, limit: TimeInterval) -> Date {
        if automaticRerun, let current { return current }
        return now.addingTimeInterval(limit)
    }

    /// Wisp has a Telegram setup of its own: the doctor names the bot job's state only when wisp.json has one.
    public static func telegramConfigured(doctor: DoctorReport) -> Bool {
        doctor.checks.first { $0.id == "telegram" }?.data["job"] != nil
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
