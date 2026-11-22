import AVFoundation
import Foundation

public final class StereoFileSink: AudioFileSink, @unchecked Sendable {
    public enum Container: Sendable { case m4a, pcm16 }

    private let lock = NSLock()
    private var file: AVAudioFile?

    public init(url: URL, container: Container) throws {
        let settings: [String: Any]
        switch container {
        case .m4a:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(CaptureFormat.sampleRate),
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
        case .pcm16:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Double(CaptureFormat.sampleRate),
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        }
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try RecordingFolder.restrictFile(at: url)
    }

    public func write(_ frames: [Float]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { throw MeetingRecorderError.sink("o arquivo de áudio já foi fechado") }
        let count = frames.count / 2
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            channels[0][index] = frames[index * 2]
            channels[1][index] = frames[index * 2 + 1]
        }
        try file.write(from: buffer)
    }

    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        file = nil
    }
}

public protocol AudioFileConverter: Sendable {
    func convert(from source: URL, to destination: URL) throws -> Double
    func convert(from source: URL, to destination: URL, progress: @Sendable (Double) -> Void) throws -> Double
}

public extension AudioFileConverter {
    func convert(from source: URL, to destination: URL, progress: @Sendable (Double) -> Void) throws -> Double {
        try convert(from: source, to: destination)
    }
}

public struct M4AFileConverter: AudioFileConverter {
    private static let chunkFrames: AVAudioFrameCount = 16_384

    public init() {}

    public static let encoderSlackFrames = 8192

    public static func covers(written: Int, total: Int) -> Bool {
        total - written <= encoderSlackFrames
    }

    public func convert(from source: URL, to destination: URL) throws -> Double {
        try convert(from: source, to: destination, progress: { _ in })
    }

    public func convert(from source: URL, to destination: URL, progress: @Sendable (Double) -> Void) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames) else {
            throw MeetingRecorderError.sink("sem memória para converter o áudio")
        }
        let sink = try StereoFileSink(url: destination, container: .m4a)
        var total = 0
        var reported = -1
        do {
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: Self.chunkFrames)
                let count = Int(buffer.frameLength)
                guard count > 0, let channels = buffer.floatChannelData else { break }
                let right = Int(format.channelCount) > 1 ? 1 : 0
                var frames = [Float](repeating: 0, count: count * 2)
                for index in 0..<count {
                    frames[index * 2] = channels[0][index]
                    frames[index * 2 + 1] = channels[right][index]
                }
                try sink.write(frames)
                total += count
                let percent = Int(Double(input.framePosition) * 100 / Double(max(1, input.length)))
                if percent != reported {
                    reported = percent
                    progress(Double(percent) / 100)
                }
            }
            try sink.finish()
            let written = try AVAudioFile(forReading: destination)
            guard Self.covers(written: Int(written.length), total: total) else {
                throw MeetingRecorderError.sink("o arquivo convertido ficou mais curto que a gravação")
            }
        } catch {
            try? sink.finish()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return Double(total) / format.sampleRate
    }
}
