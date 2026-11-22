import Foundation

public enum NudgeKind: String, Equatable, Sendable {
    case talkShare, monologue, noQuestion
}

public struct Nudge: Equatable, Identifiable, Sendable {
    public var kind: NudgeKind
    public var text: String

    public var id: String { kind.rawValue }
}

public struct NudgeEngine: Sendable {
    public static let defaultGap = 300.0
    public static let shareLimit = 0.75
    public static let minimumSpeechForShare = 300.0
    public static let monologueSeconds = 180.0
    public static let questionSilence = 600.0

    public var minimumGap: Double
    private var lastFiredAt: Double?
    private var lastByKind: [NudgeKind: Double] = [:]

    public init(minimumGap: Double = defaultGap) {
        self.minimumGap = minimumGap
    }

    public mutating func evaluate(_ stats: MeetingStats, elapsed: Double) -> Nudge? {
        if let lastFiredAt, elapsed - lastFiredAt < minimumGap { return nil }
        guard let nudge = candidate(stats, elapsed: elapsed) else { return nil }
        if let last = lastByKind[nudge.kind], elapsed - last < minimumGap * 2 { return nil }
        lastFiredAt = elapsed
        lastByKind[nudge.kind] = elapsed
        return nudge
    }

    private func candidate(_ stats: MeetingStats, elapsed: Double) -> Nudge? {
        if let ongoing = stats.ongoing, ongoing.channel == .mic, ongoing.seconds >= Self.monologueSeconds {
            return Nudge(kind: .monologue, text: "Monólogo de \(Int(ongoing.seconds / 60)) min")
        }
        let metrics = stats.metrics
        let spoken = metrics.you.speakingSeconds + metrics.others.speakingSeconds
        if spoken >= Self.minimumSpeechForShare, metrics.youShare >= Self.shareLimit {
            return Nudge(kind: .talkShare, text: "Você está falando \(Int((metrics.youShare * 100).rounded()))% do tempo")
        }
        let quiet = elapsed - (stats.lastQuestionAt ?? 0)
        if elapsed >= Self.questionSilence, quiet >= Self.questionSilence {
            return Nudge(kind: .noQuestion, text: "Nenhuma pergunta há \(Int(quiet / 60)) min")
        }
        return nil
    }
}
