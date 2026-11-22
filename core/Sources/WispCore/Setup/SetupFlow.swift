import Foundation

public enum SetupFlow {
    public static func telegramConfigured(doctor: DoctorReport) -> Bool {
        doctor.checks.first { $0.id == "telegram" }?.data["job"] != nil
    }

    public static func persisted(_ state: SetupState?, existingInstall: Bool, now: Date) -> SetupState {
        var next = state ?? SetupState()
        if existingInstall, next.finishedAt == nil { next.finishedAt = now }
        return next
    }
}
