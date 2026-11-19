import Foundation

public enum TurnRestartPolicy {
    public static func shouldRestart(
        hasProcess: Bool,
        turnsInFlight: Int,
        inTelegram: Bool,
        contended: Bool,
        lastTurnEnded: Date?,
        sessionModified: Date?,
        contextChanged: Bool = false
    ) -> Bool {
        guard hasProcess, turnsInFlight == 0 else { return false }
        return inTelegram || contended || contextChanged || changedSince(lastTurnEnded, modified: sessionModified)
    }

    public static func changedSince(_ ended: Date?, modified: Date?, grace: TimeInterval = 2) -> Bool {
        guard let ended, let modified else { return false }
        return modified > ended.addingTimeInterval(grace)
    }
}
