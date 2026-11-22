import AVFoundation
import Foundation

public enum LiveRecordingAudio {
    public static let fileName = "audio-live.m4a"

    public static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }
}

public final class LiveEncodedSink: AudioFileSink, @unchecked Sendable {
    private let lock = NSLock()
    private let raw: StereoFileSink
    private let liveURL: URL
    private var encoded: AudioFileSink?

    public convenience init(rawURL: URL) throws {
        try self.init(rawURL: rawURL, makeEncoder: { try StereoFileSink(url: $0, container: .m4a) })
    }

    init(rawURL: URL, makeEncoder: (URL) throws -> AudioFileSink) throws {
        raw = try StereoFileSink(url: rawURL, container: .pcm16)
        liveURL = LiveRecordingAudio.url(in: rawURL.deletingLastPathComponent())
        encoded = try? makeEncoder(liveURL)
    }

    public func write(_ frames: [Float]) throws {
        try raw.write(frames)
        lock.lock()
        defer { lock.unlock() }
        guard let encoded else { return }
        do {
            try encoded.write(frames)
        } catch {
            try? encoded.finish()
            self.encoded = nil
            try? FileManager.default.removeItem(at: liveURL)
        }
    }

    public func finish() throws {
        lock.lock()
        try? encoded?.finish()
        encoded = nil
        lock.unlock()
        try raw.finish()
    }
}

public struct LiveEncodedConverter: AudioFileConverter {
    private let whole = M4AFileConverter()

    public init() {}

    public func convert(from source: URL, to destination: URL) throws -> Double {
        try convert(from: source, to: destination, progress: { _ in })
    }

    public func convert(from source: URL, to destination: URL, progress: @Sendable (Double) -> Void) throws -> Double {
        let live = LiveRecordingAudio.url(in: source.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: live) }
        if let seconds = try? adopt(live: live, source: source, destination: destination) {
            progress(1)
            return seconds
        }
        return try whole.convert(from: source, to: destination, progress: progress)
    }

    private func adopt(live: URL, source: URL, destination: URL) throws -> Double {
        let raw = try AVAudioFile(forReading: source)
        let encoded = try AVAudioFile(forReading: live)
        guard M4AFileConverter.covers(written: Int(encoded.length), total: Int(raw.length)) else {
            throw MeetingRecorderError.sink("o áudio gravado ao vivo ficou mais curto que a gravação")
        }
        let tail = AVAudioFrameCount(min(4_096, encoded.length))
        guard tail > 0, let probe = AVAudioPCMBuffer(pcmFormat: encoded.processingFormat, frameCapacity: tail) else {
            throw MeetingRecorderError.sink("o áudio gravado ao vivo está vazio")
        }
        encoded.framePosition = encoded.length - AVAudioFramePosition(tail)
        try encoded.read(into: probe, frameCount: tail)
        guard probe.frameLength == tail else { throw MeetingRecorderError.sink("o áudio gravado ao vivo está truncado") }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: live, to: destination)
        try? RecordingFolder.restrictFile(at: destination)
        return Double(raw.length) / raw.processingFormat.sampleRate
    }
}
