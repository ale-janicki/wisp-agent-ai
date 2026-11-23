import Foundation

/// One explicit pause of a recording, kept in `meta.json`. `position` is where the cut sits in the saved audio
/// (the audio has no gap for the paused span), `startedAt`/`endedAt` are the wall-clock times of the pause.
public struct RecordingPause: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date?
    public var position: Double

    public init(startedAt: Date, endedAt: Date? = nil, position: Double) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case position = "at_s"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    public func label(timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let from = formatter.string(from: startedAt)
        guard let endedAt else { return "Pausado desde \(from)" }
        return "Pausado \(from)–\(formatter.string(from: endedAt))"
    }
}

/// Decides which captured buffers survive a pause and where the survivors land on the recording's timeline.
/// Times are the capture clock (`RingSlot.time`). A buffer stamped inside a pause is dropped; every buffer after a
/// pause is shifted back by the pause's length, so the saved audio and the live transcript are continuous.
public struct CaptureGate: Equatable, Sendable {
    private struct Cut: Equatable, Sendable {
        var start: Double
        var end: Double
    }

    private var cuts: [Cut] = []
    private var openSince: Double?

    public init() {}

    public var isPaused: Bool { openSince != nil }

    public mutating func pause(at now: Double) {
        if openSince == nil { openSince = now }
    }

    public mutating func resume(at now: Double) {
        guard let since = openSince else { return }
        cuts.append(Cut(start: since, end: max(since, now)))
        openSince = nil
    }

    /// The time to use for a buffer stamped `time`, or nil when the buffer was captured while paused.
    public func admit(_ time: Double) -> Double? {
        if let openSince, time >= openSince { return nil }
        var shift = 0.0
        for cut in cuts {
            if time >= cut.end {
                shift += cut.end - cut.start
            } else if time >= cut.start {
                return nil
            }
        }
        return time - shift
    }
}
