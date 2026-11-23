import Foundation

public struct MeetingBookmark: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var time: Double
    public var label: String

    public init(id: String = UUID().uuidString, time: Double, label: String = "") {
        self.id = id
        self.time = time
        self.label = label
    }
}

public enum MeetingBookmarks {
    public static let linesBefore = 3
    public static let linesAfter = 2

    public static func lines(
        segments: [MeetingSegment], bookmarks: [MeetingBookmark], pauses: [RecordingPause] = [], timeZone: TimeZone = .current
    ) -> [TranscriptLine] {
        let pauseLines = pauses.map { (time: $0.position, line: TranscriptLine(pause: $0, timeZone: timeZone)) }
        let marks = bookmarks.map { (time: $0.time, id: $0.id, line: TranscriptLine(bookmark: $0)) }
            + pauseLines.map { (time: $0.time, id: $0.line.id, line: $0.line) }
        let ordered = marks.sorted { ($0.time, $0.id) < ($1.time, $1.id) }
        var out: [TranscriptLine] = []
        var next = 0
        for segment in segments {
            while next < ordered.count, ordered[next].time < segment.start {
                out.append(ordered[next].line)
                next += 1
            }
            out.append(TranscriptLine(segment))
        }
        while next < ordered.count {
            out.append(ordered[next].line)
            next += 1
        }
        return out
    }

    public static func surrounding(_ segments: [MeetingSegment], at time: Double) -> [MeetingSegment] {
        let spoken = segments.filter { $0.isFinal && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        let before = spoken.filter { $0.start <= time }.suffix(linesBefore)
        let after = spoken.filter { $0.start > time }.prefix(linesAfter)
        return Array(before) + Array(after)
    }
}
