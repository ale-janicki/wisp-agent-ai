@preconcurrency import AVFoundation
import Foundation

public enum TranscriptTidy {
    public static func mergeAdjacent(_ segments: [MeetingSegment], maxGap: Double = 1.5, maxCharacters: Int = 320) -> [MeetingSegment] {
        var out: [MeetingSegment] = []
        for segment in segments.sorted(by: { ($0.start, $0.speaker) < ($1.start, $1.speaker) }) {
            let text = segment.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { continue }
            if var last = out.last, last.speaker == segment.speaker, segment.start - last.end <= maxGap,
               last.text.count + text.count < maxCharacters {
                last.text += " " + text
                last.end = max(last.end, segment.end)
                if let a = last.confidence, let b = segment.confidence { last.confidence = min(a, b) }
                out[out.count - 1] = last
            } else {
                var copy = segment
                copy.text = text
                out.append(copy)
            }
        }
        return out
    }
}

public struct StereoAudioReader: Sendable {
    public static let blockFrames: AVAudioFrameCount = 48_000

    public init() {}

    public static func audioURL(in folder: URL, fileManager: FileManager = .default) -> URL? {
        [RecordingFolder.audioURL(in: folder), RecordingFolder.rawAudioURL(in: folder)].first {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    public func read(
        _ url: URL, onBlock: ([AudioChannel: [Float]], Double) async throws -> Void
    ) async throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.blockFrames) else {
            throw MeetingTranscriberError.audio("sem memória para ler o áudio")
        }
        let channelCount = Int(format.channelCount)
        var decimators = [Decimator48To16](repeating: Decimator48To16(), count: 2)
        var resamplers = [LinearResampler](repeating: LinearResampler(from: format.sampleRate, to: Double(SpeechAudio.sampleRate)), count: 2)
        let native = format.sampleRate == 48_000
        let length = max(1, file.length)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: Self.blockFrames)
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            var block: [AudioChannel: [Float]] = [:]
            for (index, channel) in AudioChannel.allCases.enumerated() where index < channelCount {
                let samples = Array(UnsafeBufferPointer(start: data[index], count: count))
                block[channel] = native ? decimators[index].process(samples) : resamplers[index].process(samples)
            }
            try await onBlock(block, Double(file.framePosition) / Double(length))
        }
    }
}

public enum MeetingTranscriberError: Error, LocalizedError, Equatable {
    case noAudio
    case audio(String)

    public var errorDescription: String? {
        switch self {
        case .noAudio: "Não encontrei o áudio dessa gravação."
        case .audio(let message): "Não consegui ler o áudio: \(message)"
        }
    }
}

public struct MeetingTranscriber: Sendable {
    public var recognizer: SpeechRecognizer
    public var language: String?
    public var config: ChannelStreamerConfig
    public var pause: (@Sendable () async throws -> Void)?

    public init(
        recognizer: SpeechRecognizer, language: String? = nil, config: ChannelStreamerConfig = .default,
        pause: (@Sendable () async throws -> Void)? = nil
    ) {
        self.recognizer = recognizer
        self.language = language
        self.config = config
        self.pause = pause
    }

    public func transcribe(
        folder: URL, startedAt: Date, sources: RecordingSources = .both, duration: Double,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> MeetingTranscriptDocument {
        guard let audio = StereoAudioReader.audioURL(in: folder) else { throw MeetingTranscriberError.noAudio }
        var merger = TranscriptMerger()
        var streamers: [AudioChannel: ChannelStreamer] = [:]
        for channel in AudioChannel.allCases where Self.uses(channel, sources) {
            streamers[channel] = ChannelStreamer(channel: channel, config: config)
        }
        var noise: [NoiseRange] = []
        func run(_ jobs: [StreamJob], into merger: inout TranscriptMerger) async throws {
            for job in jobs where job.kind == .noise {
                noise.append(NoiseRange(channel: job.channel, start: job.startSeconds, end: job.endSeconds))
            }
            for job in jobs where !job.samples.isEmpty {
                try Task.checkCancellation()
                try await pause?()
                let spans = try await recognizer.transcribe(job.samples, language: language).map {
                    RecognizedSpan(
                        text: $0.text, start: $0.start + job.startSeconds, end: $0.end + job.startSeconds, confidence: $0.confidence
                    )
                }
                merger.commit(spans, channel: job.channel)
            }
        }
        try await StereoAudioReader().read(audio) { block, fraction in
            for (channel, samples) in block {
                guard var streamer = streamers[channel] else { continue }
                let jobs = streamer.append(samples)
                streamers[channel] = streamer
                try await run(jobs, into: &merger)
            }
            progress(fraction * 0.98)
        }
        for channel in AudioChannel.allCases {
            guard var streamer = streamers[channel] else { continue }
            let jobs = streamer.flush()
            streamers[channel] = streamer
            try await run(jobs, into: &merger)
        }
        if !noise.isEmpty {
            try await fill(noise, audio: audio, into: &merger, progress: { progress(0.98 + $0 * 0.02) })
        }
        progress(1)
        let tidy = TranscriptTidy.mergeAdjacent(merger.finals)
        let spoken = tidy.map(\.end).max() ?? 0
        return MeetingTranscriptDocument(
            startedAt: startedAt, durationSeconds: max(duration, spoken), language: language ?? "auto",
            engine: recognizer.engineName, segments: tidy
        )
    }

    public func transcribeRanges(
        folder: URL, ranges: [NoiseRange], progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [MeetingSegment] {
        guard let audio = StereoAudioReader.audioURL(in: folder) else { throw MeetingTranscriberError.noAudio }
        var merger = TranscriptMerger()
        try await fill(ranges, audio: audio, into: &merger, progress: progress)
        return merger.finals
    }

    private static let pieceSamples = 20 * SpeechAudio.sampleRate
    private static let pieceOverlap = SpeechAudio.sampleRate / 2
    private static let minimumPieceSamples = SpeechAudio.sampleRate / 10

    private struct Piece {
        var start = 0
        var samples: [Float] = []
        var fresh = 0
    }

    private func fill(
        _ ranges: [NoiseRange], audio: URL, into merger: inout TranscriptMerger, progress: @Sendable (Double) -> Void
    ) async throws {
        let rate = Double(SpeechAudio.sampleRate)
        var position: [AudioChannel: Int] = [:]
        var pieces: [AudioChannel: Piece] = [:]
        func transcribe(_ channel: AudioChannel, _ piece: Piece, into merger: inout TranscriptMerger) async throws {
            guard piece.fresh >= Self.minimumPieceSamples else { return }
            try Task.checkCancellation()
            try await pause?()
            let offset = Double(piece.start) / rate
            let spans = try await recognizer.transcribe(piece.samples, language: language).map {
                RecognizedSpan(text: $0.text, start: $0.start + offset, end: $0.end + offset, confidence: $0.confidence)
            }
            merger.commit(spans, channel: channel)
        }
        func inside(_ channel: AudioChannel, _ index: Int) -> Bool {
            ranges.contains { $0.channel == channel && Double(index) >= $0.start * rate && Double(index) < $0.end * rate }
        }
        try await StereoAudioReader().read(audio) { block, fraction in
            for (channel, samples) in block where ranges.contains(where: { $0.channel == channel }) {
                let first = position[channel] ?? 0
                var piece = pieces[channel] ?? Piece()
                for (offset, sample) in samples.enumerated() {
                    let index = first + offset
                    guard inside(channel, index) else {
                        if piece.fresh > 0 {
                            try await transcribe(channel, piece, into: &merger)
                            piece = Piece()
                        } else if !piece.samples.isEmpty {
                            piece = Piece()
                        }
                        continue
                    }
                    if piece.samples.isEmpty { piece.start = index }
                    piece.samples.append(sample)
                    piece.fresh += 1
                    if piece.samples.count >= Self.pieceSamples {
                        try await transcribe(channel, piece, into: &merger)
                        let keep = Array(piece.samples.suffix(Self.pieceOverlap))
                        piece = Piece(start: index + 1 - keep.count, samples: keep, fresh: 0)
                    }
                }
                position[channel] = first + samples.count
                pieces[channel] = piece
            }
            progress(fraction)
        }
        for (channel, piece) in pieces where piece.fresh > 0 {
            try await transcribe(channel, piece, into: &merger)
        }
    }

    static func uses(_ channel: AudioChannel, _ sources: RecordingSources) -> Bool {
        switch channel {
        case .mic: sources.usesMic
        case .system: sources.usesSystem
        }
    }
}
