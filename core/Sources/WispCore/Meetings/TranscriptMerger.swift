import Foundation

public struct RecognizedSpan: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct TranscriptMerger: Sendable {
    public static let maxOverlapWords = 12
    public static let overlapToleranceSeconds = 0.75

    public private(set) var finals: [MeetingSegment] = []
    private var partials: [AudioChannel: MeetingSegment] = [:]

    public init() {}

    public var snapshot: [MeetingSegment] {
        let live = partials.values.filter { !$0.text.isEmpty }
        return (finals + live).sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    }

    public var lastFinalEnd: [AudioChannel: Double] {
        var out: [AudioChannel: Double] = [:]
        for segment in finals {
            guard let channel = segment.channel else { continue }
            out[channel] = max(out[channel] ?? 0, segment.end)
        }
        return out
    }

    public mutating func setPartial(_ span: RecognizedSpan?, channel: AudioChannel) {
        guard let span, let text = Self.clean(span.text) else {
            partials[channel] = nil
            return
        }
        var trimmed = text
        if let last = lastFinal(of: channel), span.start < last.end + Self.overlapToleranceSeconds {
            trimmed = Self.dropRepeatedPrefix(of: text, after: last.text)
        }
        guard !trimmed.isEmpty else {
            partials[channel] = nil
            return
        }
        partials[channel] = MeetingSegment(
            start: span.start, end: span.end, speaker: channel.speaker, text: trimmed, confidence: span.confidence, isFinal: false
        )
    }

    public mutating func commit(_ spans: [RecognizedSpan], channel: AudioChannel) {
        partials[channel] = nil
        for span in spans {
            guard var text = Self.clean(span.text) else { continue }
            if let last = lastFinal(of: channel), span.start < last.end + Self.overlapToleranceSeconds {
                text = Self.dropRepeatedPrefix(of: text, after: last.text)
            }
            guard !text.isEmpty else { continue }
            finals.append(MeetingSegment(
                start: span.start, end: max(span.end, span.start), speaker: channel.speaker, text: text,
                confidence: span.confidence, isFinal: true
            ))
        }
        finals.sort { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    }

    private func lastFinal(of channel: AudioChannel) -> MeetingSegment? {
        finals.last { $0.speaker == channel.speaker }
    }

    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedWord(_ word: Substring) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func dropRepeatedPrefix(of text: String, after previous: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let before = previous.split(whereSeparator: \.isWhitespace).map(normalizedWord).filter { !$0.isEmpty }
        let current = words.map(normalizedWord)
        let limit = min(maxOverlapWords, before.count, current.count)
        guard limit > 0 else { return text }
        for size in stride(from: limit, through: 1, by: -1) where Array(before.suffix(size)) == Array(current.prefix(size)) {
            return words.dropFirst(size).joined(separator: " ")
        }
        return text
    }
}
