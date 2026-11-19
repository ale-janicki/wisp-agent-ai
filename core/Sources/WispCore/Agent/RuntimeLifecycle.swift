import Foundation

public struct RuntimeSnapshot: Equatable, Sendable {
    public let id: UUID
    public let isCurrent: Bool
    public let hasProcess: Bool
    public let isBusy: Bool
    public let hasUnseenReply: Bool
    public let lastUsed: Date

    public init(id: UUID, isCurrent: Bool, hasProcess: Bool, isBusy: Bool, hasUnseenReply: Bool = false, lastUsed: Date) {
        self.id = id
        self.isCurrent = isCurrent
        self.hasProcess = hasProcess
        self.isBusy = isBusy
        self.hasUnseenReply = hasUnseenReply
        self.lastUsed = lastUsed
    }
}

public enum RuntimeLifecycle {
    public static let keepWarm = 4
    public static let idleTimeout: TimeInterval = 600

    public static func processesToStop(
        _ runtimes: [RuntimeSnapshot],
        now: Date,
        keepWarm: Int = keepWarm,
        idleTimeout: TimeInterval = idleTimeout
    ) -> [UUID] {
        let idle = runtimes
            .filter { $0.hasProcess && !$0.isBusy }
            .sorted { $0.lastUsed > $1.lastUsed }
        var stop: [UUID] = []
        for (rank, runtime) in idle.enumerated() where !runtime.isCurrent {
            if rank >= keepWarm || now.timeIntervalSince(runtime.lastUsed) > idleTimeout { stop.append(runtime.id) }
        }
        return stop
    }

    public static func runtimesToDrop(_ runtimes: [RuntimeSnapshot]) -> [UUID] {
        runtimes
            .filter { !$0.isCurrent && !$0.hasProcess && !$0.isBusy && !$0.hasUnseenReply }
            .map(\.id)
    }
}

public enum RowActivity: Equatable, Sendable {
    case none
    case thinking
    case attention
    case sharing

    public static func of(
        isCurrent: Bool, isThinking: Bool, hasApproval: Bool, hasUnseenReply: Bool, isSharing: Bool = false
    ) -> RowActivity {
        if isSharing { return .sharing }
        guard !isCurrent else { return .none }
        if hasApproval || hasUnseenReply { return .attention }
        return isThinking ? .thinking : .none
    }
}
