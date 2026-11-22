import Foundation

public enum AudioChannel: String, Codable, CaseIterable, Sendable {
    case mic
    case system

    public var speaker: String {
        switch self {
        case .mic: "eu"
        case .system: "outros"
        }
    }

    public var displayName: String {
        switch self {
        case .mic: "Você"
        case .system: "Outros"
        }
    }

    public init?(speaker: String) {
        guard let match = Self.allCases.first(where: { $0.speaker == speaker }) else { return nil }
        self = match
    }
}

public struct MeetingSegment: Codable, Equatable, Identifiable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    public var confidence: Double?
    public var isFinal = true

    public init(start: Double, end: Double, speaker: String, text: String, confidence: Double? = nil, isFinal: Bool = true) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
    }

    public var id: String {
        isFinal ? "\(speaker)-\(Int((start * 1000).rounded()))" : "\(speaker)-partial"
    }

    public var channel: AudioChannel? { AudioChannel(speaker: speaker) }

    public var speakerName: String { channel?.displayName ?? speaker }

    private enum CodingKeys: String, CodingKey { case start, end, speaker, text, confidence }
}

public struct MeetingTranscriptDocument: Codable, Equatable, Sendable {
    public static let fileName = "transcript.json"
    public static let liveFileName = "transcript.live.json"

    public var version = 1
    public var startedAt: Date
    public var durationSeconds: Double
    public var language: String
    public var engine: String
    public var segments: [MeetingSegment]
    public var failedSegments: Int?

    public init(startedAt: Date, durationSeconds: Double, language: String = "auto", engine: String, segments: [MeetingSegment]) {
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.language = language
        self.engine = engine
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey {
        case version, language, engine, segments
        case failedSegments = "failed_segments"
        case startedAt = "started_at"
        case durationSeconds = "duration_s"
    }

    public func plainText() -> String {
        segments.map { "[\(ElapsedFormat.clock($0.start))] \($0.speakerName): \($0.text)" }.joined(separator: "\n")
    }
}

public enum MeetingTranscriptFile {
    public static func url(in folder: URL, live: Bool = false) -> URL {
        folder.appendingPathComponent(live ? MeetingTranscriptDocument.liveFileName : MeetingTranscriptDocument.fileName)
    }

    public static func write(_ document: MeetingTranscriptDocument, in folder: URL, live: Bool = false) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let target = url(in: folder, live: live)
        try encoder.encode(document).write(to: target, options: .atomic)
        try RecordingFolder.restrictFile(at: target)
    }

    public static func read(in folder: URL, live: Bool = false) throws -> MeetingTranscriptDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingTranscriptDocument.self, from: Data(contentsOf: url(in: folder, live: live)))
    }

    public static func exists(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: folder).path)
    }
}
