import Foundation

public struct ChannelMetrics: Codable, Equatable, Sendable {
    public var words = 0
    public var speakingSeconds = 0.0
    public var wordsPerMinute = 0.0
    public var questions = 0
    public var longestMonologueSeconds = 0.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case words, questions
        case speakingSeconds = "speaking_s"
        case wordsPerMinute = "wpm"
        case longestMonologueSeconds = "longest_monologue_s"
    }
}

public struct MeetingMetrics: Codable, Equatable, Sendable {
    public var durationSeconds: Double
    public var you: ChannelMetrics
    public var others: ChannelMetrics
    public var silenceSeconds: Double

    public init(durationSeconds: Double = 0, you: ChannelMetrics = ChannelMetrics(), others: ChannelMetrics = ChannelMetrics(), silenceSeconds: Double = 0) {
        self.durationSeconds = durationSeconds
        self.you = you
        self.others = others
        self.silenceSeconds = silenceSeconds
    }

    public var youShare: Double {
        let total = you.speakingSeconds + others.speakingSeconds
        return total > 0 ? you.speakingSeconds / total : 0
    }

    private enum CodingKeys: String, CodingKey {
        case you, others
        case durationSeconds = "duration_s"
        case silenceSeconds = "silence_s"
    }
}

public struct Monologue: Equatable, Sendable {
    public var channel: AudioChannel
    public var seconds: Double

    public init(channel: AudioChannel, seconds: Double) {
        self.channel = channel
        self.seconds = seconds
    }
}

public struct MeetingStats: Equatable, Sendable {
    public var metrics: MeetingMetrics
    public var ongoing: Monologue?
    public var lastQuestionAt: Double?

    public init(metrics: MeetingMetrics, ongoing: Monologue?, lastQuestionAt: Double?) {
        self.metrics = metrics
        self.ongoing = ongoing
        self.lastQuestionAt = lastQuestionAt
    }
}

public enum MeetingMetricsCalculator {
    public static let monologueGap = 4.0
    public static let interjectionWords = 2
    public static let ongoingWindow = 8.0
    public static let minimumSpeechForRate = 10.0

    public static func compute(_ segments: [MeetingSegment], elapsed: Double) -> MeetingStats {
        let spoken = segments
            .filter { $0.isFinal && $0.channel != nil && $0.end >= $0.start && wordCount($0.text) > 0 }
            .sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
        var you = ChannelMetrics()
        var others = ChannelMetrics()
        var lastQuestion: Double?
        for segment in spoken {
            let asked = questionCount(segment.text)
            if asked > 0 { lastQuestion = max(lastQuestion ?? 0, segment.start) }
            if segment.channel == .mic {
                you.words += wordCount(segment.text)
                you.questions += asked
            } else {
                others.words += wordCount(segment.text)
                others.questions += asked
            }
        }
        you.speakingSeconds = covered(spoken.filter { $0.channel == .mic })
        others.speakingSeconds = covered(spoken.filter { $0.channel == .system })
        you.wordsPerMinute = rate(words: you.words, seconds: you.speakingSeconds)
        others.wordsPerMinute = rate(words: others.words, seconds: others.speakingSeconds)
        let runs = monologues(spoken)
        you.longestMonologueSeconds = runs.filter { $0.channel == .mic }.map(\.seconds).max() ?? 0
        others.longestMonologueSeconds = runs.filter { $0.channel == .system }.map(\.seconds).max() ?? 0
        let duration = max(elapsed, spoken.map(\.end).max() ?? 0)
        let silence = max(0, duration - covered(spoken, upTo: duration))
        var ongoing: Monologue?
        if let last = runs.last, elapsed - last.end <= ongoingWindow { ongoing = Monologue(channel: last.channel, seconds: last.seconds) }
        return MeetingStats(
            metrics: MeetingMetrics(durationSeconds: duration, you: you, others: others, silenceSeconds: silence),
            ongoing: ongoing, lastQuestionAt: lastQuestion
        )
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func questionCount(_ text: String) -> Int {
        var count = 0
        var previousWasMark = false
        for character in text {
            let mark = character == "?"
            if mark, !previousWasMark { count += 1 }
            previousWasMark = mark
        }
        return count
    }

    private static func rate(words: Int, seconds: Double) -> Double {
        seconds >= minimumSpeechForRate ? Double(words) / (seconds / 60) : 0
    }

    private static func covered(_ segments: [MeetingSegment], upTo limit: Double = .infinity) -> Double {
        var total = 0.0
        var end = -Double.infinity
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let from = max(segment.start, end)
            let to = min(segment.end, limit)
            if to > from { total += to - from }
            end = max(end, segment.end)
        }
        return total
    }

    private struct Run {
        var channel: AudioChannel
        var start: Double
        var end: Double
        var seconds: Double { end - start }
    }

    private static func monologues(_ spoken: [MeetingSegment]) -> [Run] {
        var runs: [Run] = []
        for segment in spoken {
            guard let channel = segment.channel else { continue }
            if var current = runs.last {
                if current.channel == channel, segment.start - current.end <= monologueGap {
                    current.end = max(current.end, segment.end)
                    runs[runs.count - 1] = current
                    continue
                }
                if current.channel != channel, wordCount(segment.text) <= interjectionWords { continue }
            }
            runs.append(Run(channel: channel, start: segment.start, end: segment.end))
        }
        return runs
    }
}
