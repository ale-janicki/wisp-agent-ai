import AVFoundation
import Foundation

extension AudioChannel {
    var index: Int { self == .mic ? 0 : 1 }
}

/// Mean-square level of one channel per half second, kept while the channel is exported so the hallucination filter
/// can tell whether a phrase was said over real speech or over silence.
public struct ChannelEnvelope: Equatable, Sendable {
    public static let window = 0.5

    public var meanSquares: [Float]

    public init(meanSquares: [Float] = []) { self.meanSquares = meanSquares }

    public func rms(from start: Double, to end: Double) -> Float {
        guard !meanSquares.isEmpty else { return 0 }
        let first = min(max(0, Int(start / Self.window)), meanSquares.count - 1)
        let last = min(max(first, Int((end / Self.window).rounded(.up)) - 1), meanSquares.count - 1)
        let slice = meanSquares[first...last]
        return (slice.reduce(0, +) / Float(slice.count)).squareRoot()
    }
}

public enum WhisperOutput {
    struct File: Decodable {
        struct Entry: Decodable {
            struct Offsets: Decodable { var from: Int; var to: Int }
            var offsets: Offsets
            var text: String
        }
        var transcription: [Entry]
    }

    public static func parse(_ data: Data) throws -> [RecognizedSpan] {
        try JSONDecoder().decode(File.self, from: data).transcription.map {
            RecognizedSpan(text: $0.text, start: Double($0.offsets.from) / 1000, end: Double($0.offsets.to) / 1000)
        }
    }
}

public enum WhisperHallucination {
    public static let silenceRMS: Float = 0.004
    public static let repeatLimit = 3

    /// Phrases Whisper invents over silence or music; dropped when the segment is little more than the phrase itself.
    static let phrases = [
        "legenda por", "legendas pela comunidade", "transcricao e legendas", "se inscreva no canal", "ative o sininho",
        "obrigado por assistir", "a cidade no brasil", "acesse o nosso site", "amara org",
    ]
    /// Short fillers that are real speech when said over audio, so they only go when the segment is silent.
    static let silentOnly = ["tchau tchau", "obrigado", "obrigada", "aplausos", "e ai", "musica"]
    static let phraseSlack = 30

    public static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
        let words = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(words).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static let loopLimit = 4
    static let loopWords = 4

    public static func collapseLoops(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = words.map(normalized)
        var out: [String] = []
        var index = 0
        scan: while index < words.count {
            for size in 1...loopWords {
                var reps = 1
                while index + (reps + 1) * size <= words.count,
                      keys[(index + reps * size)..<(index + (reps + 1) * size)] == keys[index..<(index + size)] { reps += 1 }
                guard reps >= loopLimit, index + size <= words.count else { continue }
                out += words[index..<(index + size)]
                index += size * reps
                continue scan
            }
            out.append(words[index])
            index += 1
        }
        return out.joined(separator: " ")
    }

    static let nordicLetters = Set("ðþæøå")
    static let nordicWords: Set<String> = ["hvað", "að", "ég", "eftir", "segja", "ekki", "og"]

    /// Icelandic/Nordic text Whisper invents over noise when told the call is in Portuguese or Spanish: two or more
    /// tokens with those letters or from those words (one alone could be a name).
    public static func isNordicGibberish(_ text: String) -> Bool {
        let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return tokens.filter { $0.contains(where: nordicLetters.contains) || nordicWords.contains($0) }.count >= 2
    }

    static func isInvented(_ span: RecognizedSpan, envelope: ChannelEnvelope, language: MeetingLanguage) -> Bool {
        if language == .pt || language == .es, isNordicGibberish(span.text) { return true }
        let text = normalized(span.text)
        if text.isEmpty { return true }
        if phrases.contains(where: { text.contains($0) && text.count <= $0.count + phraseSlack }) { return true }
        guard silentOnly.contains(text) else { return false }
        return envelope.rms(from: span.start, to: span.end) < silenceRMS
    }

    public static func filter(
        _ spans: [RecognizedSpan], envelope: ChannelEnvelope, language: MeetingLanguage = .pt
    ) -> (kept: [RecognizedSpan], dropped: Int) {
        var out: [RecognizedSpan] = []
        var runStart = 0
        var survivors = spans.filter { !isInvented($0, envelope: envelope, language: language) }
        for index in survivors.indices { survivors[index].text = collapseLoops(survivors[index].text) }
        while runStart < survivors.count {
            let text = normalized(survivors[runStart].text)
            var runEnd = runStart
            while runEnd + 1 < survivors.count, normalized(survivors[runEnd + 1].text) == text { runEnd += 1 }
            let length = runEnd - runStart + 1
            out += length >= repeatLimit ? [survivors[runStart]] : Array(survivors[runStart...runEnd])
            runStart = runEnd + 1
        }
        return (out, spans.count - out.count)
    }
}

public enum WhisperCommand {
    public static let threads = 4

    /// `-mc 0` keeps each window independent: with the default context Whisper loops on one hallucinated line
    /// ("Legenda por ..." 144 times in 4 min of the same audio) once it appears.
    /// `-l auto` for detection: whisper-cli's own default is English, so leaving `-l` out would force English.
    public static func arguments(
        model: URL, language: MeetingLanguage, input: URL, outputBase: URL, vad: URL? = nil
    ) -> [String] {
        var args = ["-m", model.path, "-l", language.whisperCode ?? "auto", "-t", String(threads), "-mc", "0", "-oj", "-np", "-pp"]
        if let vad { args += ["--vad", "-vm", vad.path] }
        args += ["-of", outputBase.path, input.path]
        return args
    }
}

public enum WhisperLocator {
    public static let homebrew = ["/opt/homebrew/bin", "/usr/local/bin"]

    public static func binary(searchPATH: String, fallback: [String] = homebrew, fileManager: FileManager = .default) -> URL? {
        for directory in searchPATH.split(separator: ":").map(String.init) + fallback {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("whisper-cli")
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static func modelsFolder(wispDir: URL) -> URL {
        SpeechModelLocation.root(wispDir: wispDir).appendingPathComponent("whisper", isDirectory: true)
    }
}

/// One Whisper process at a time across every meeting: three at once crashed a 16 GB Mac.
actor WhisperQueue {
    static let shared = WhisperQueue()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

public struct RefineResult: Sendable {
    public var document: MeetingTranscriptDocument?
    public var notice: String?
    public var dropped = 0
}

/// Re-transcribes a finished call with Whisper at a fixed language. Never throws: any problem keeps the live transcript.
public struct PostCallRefiner: Sendable {
    public var engine: PostCallEngine
    public var language: MeetingLanguage
    public var wispDir: URL
    public var searchPATH: @Sendable () -> String
    public var isRecording: @Sendable () async -> Bool
    public var useVAD = false

    public init(
        engine: PostCallEngine, language: MeetingLanguage, wispDir: URL,
        searchPATH: @escaping @Sendable () -> String, isRecording: @escaping @Sendable () async -> Bool
    ) {
        self.engine = engine
        self.language = language
        self.wispDir = wispDir
        self.searchPATH = searchPATH
        self.isRecording = isRecording
    }

    public static let tempFolderName = ".whisper-tmp"

    public func refine(
        folder: URL, meta: RecordingMeta, original: MeetingTranscriptDocument, progress: @escaping @Sendable (Double) -> Void
    ) async -> RefineResult {
        guard let modelName = engine.modelFileName else { return RefineResult() }
        guard let binary = WhisperLocator.binary(searchPATH: searchPATH()) else {
            return RefineResult(notice: "Não achei o whisper-cli (brew install whisper-cpp); mantive a transcrição ao vivo.")
        }
        let models = WhisperLocator.modelsFolder(wispDir: wispDir)
        let model = models.appendingPathComponent(modelName)
        guard FileManager.default.fileExists(atPath: model.path) else {
            return RefineResult(notice: "Modelo \(modelName) não está em \(models.path); mantive a transcrição ao vivo.")
        }
        let vad = useVAD ? models.appendingPathComponent("ggml-silero-v5.1.2.bin") : nil
        guard let audio = StereoAudioReader.audioURL(in: folder) else {
            return RefineResult(notice: "Não achei o áudio para revisar a transcrição; mantive a transcrição ao vivo.")
        }
        let temp = folder.appendingPathComponent(Self.tempFolderName, isDirectory: true)
        try? FileManager.default.removeItem(at: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let channels = AudioChannel.allCases.filter { MeetingTranscriber.uses($0, meta.sources ?? .both) }
            let exports = try await Self.export(audio: audio, channels: channels, into: temp)
            var merger = TranscriptMerger()
            var dropped = 0
            for (index, channel) in channels.enumerated() {
                guard let export = exports[channel] else { continue }
                let spans = try await transcribe(
                    wav: export.url, binary: binary, model: model, vad: vad, temp: temp,
                    progress: { progress((Double(index) + $0) / Double(channels.count)) }
                )
                let result = WhisperHallucination.filter(spans, envelope: export.envelope, language: language)
                dropped += result.dropped
                merger.commit(result.kept, channel: channel)
            }
            let segments = TranscriptTidy.mergeAdjacent(merger.finals)
            guard !segments.isEmpty else {
                return RefineResult(notice: "O Whisper não achou fala nessa gravação; mantive a transcrição ao vivo.", dropped: dropped)
            }
            var document = original
            document.segments = segments
            document.engine = engine.engineName
            document.language = language.rawValue
            document.failedSegments = nil
            document.noiseRanges = nil
            document.durationSeconds = max(original.durationSeconds, segments.map(\.end).max() ?? 0)
            progress(1)
            return RefineResult(document: document, dropped: dropped)
        } catch is CancellationError {
            return RefineResult(notice: "A revisão da transcrição foi cancelada; mantive a transcrição ao vivo.")
        } catch {
            return RefineResult(notice: "Não consegui revisar a transcrição (\(error.localizedDescription)); mantive a transcrição ao vivo.")
        }
    }

    struct Export {
        var url: URL
        var envelope: ChannelEnvelope
    }

    /// Splits the stereo recording into one 16 kHz mono WAV per channel. The sample-rate conversion is AVAudioConverter at
    /// maximum quality: the live path's 3-sample average aliases high frequencies, which Whisper is far less forgiving of.
    static func export(audio: URL, channels: [AudioChannel], into temp: URL) async throws -> [AudioChannel: Export] {
        let file = try AVAudioFile(forReading: audio)
        let source = file.processingFormat
        let rate = Double(SpeechAudio.sampleRate)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: source.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: StereoAudioReader.blockFrames),
              let output = AVAudioPCMBuffer(
                  pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(StereoAudioReader.blockFrames) * rate / source.sampleRate) + 4096
              ) else { throw MeetingTranscriberError.audio("sem memória para ler o áudio") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let present = channels.filter { Int(source.channelCount) > $0.index }
        var writers: [AudioChannel: WavWriter] = [:]
        var meanSquares: [AudioChannel: [Float]] = [:]
        var pending: [AudioChannel: (sum: Float, count: Int)] = [:]
        let windowSamples = Int(ChannelEnvelope.window * rate)
        for channel in present { writers[channel] = try WavWriter(url: temp.appendingPathComponent("\(channel.rawValue).wav")) }

        func drain() throws {
            guard output.frameLength > 0, let data = output.floatChannelData else { return }
            for channel in present {
                let samples = Array(UnsafeBufferPointer(start: data[channel.index], count: Int(output.frameLength)))
                try writers[channel]?.append(samples)
                var state = pending[channel] ?? (0, 0)
                for sample in samples {
                    state.sum += sample * sample
                    state.count += 1
                    if state.count == windowSamples {
                        meanSquares[channel, default: []].append(state.sum / Float(windowSamples))
                        state = (0, 0)
                    }
                }
                pending[channel] = state
            }
        }
        func convert(_ block: (AVAudioConverterInputStatus) -> AVAudioBuffer?) throws {
            var failure: NSError?
            _ = converter.convert(to: output, error: &failure) { _, status in
                guard let buffer = block(.haveData) else {
                    status.pointee = .endOfStream
                    return nil
                }
                status.pointee = .haveData
                return buffer
            }
            if let failure { throw MeetingTranscriberError.audio(failure.localizedDescription) }
            try drain()
        }

        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: input, frameCount: StereoAudioReader.blockFrames)
            guard input.frameLength > 0 else { break }
            var given = false
            var failure: NSError?
            _ = converter.convert(to: output, error: &failure) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return input
            }
            if let failure { throw MeetingTranscriberError.audio(failure.localizedDescription) }
            try drain()
        }
        try convert { _ in nil }

        var out: [AudioChannel: Export] = [:]
        for channel in present {
            guard let writer = writers[channel] else { continue }
            if let tail = pending[channel], tail.count > 0 { meanSquares[channel, default: []].append(tail.sum / Float(tail.count)) }
            try writer.finish()
            out[channel] = Export(url: writer.url, envelope: ChannelEnvelope(meanSquares: meanSquares[channel] ?? []))
        }
        return out
    }

    private func transcribe(
        wav: URL, binary: URL, model: URL, vad: URL?, temp: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [RecognizedSpan] {
        while await isRecording() { try await Task.sleep(for: .seconds(2)) }
        await WhisperQueue.shared.acquire()
        do {
            let base = wav.deletingPathExtension()
            let log = base.appendingPathExtension("log")
            let arguments = WhisperCommand.arguments(model: model, language: language, input: wav, outputBase: base, vad: vad)
            try await WhisperProcess.run(
                binary: binary, arguments: arguments, log: log, isRecording: isRecording, progress: progress
            )
            await WhisperQueue.shared.release()
            return try WhisperOutput.parse(Data(contentsOf: base.appendingPathExtension("json")))
        } catch {
            await WhisperQueue.shared.release()
            throw error
        }
    }
}

enum WhisperProcessError: Error, LocalizedError {
    case failed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .failed(let code, let tail): "whisper-cli saiu com código \(code)\(tail.isEmpty ? "" : ": \(tail)")"
        }
    }
}

enum WhisperProcess {
    static func run(
        binary: URL, arguments: [String], log: URL, isRecording: @escaping @Sendable () async -> Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = ["-n", "10", binary.path] + arguments
        process.qualityOfService = .utility
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        let control = ProcessControl(process)
        let watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                control.setPaused(await isRecording())
                if let fraction = tailProgress(log) { progress(fraction) }
            }
        }
        defer { watcher.cancel() }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                    if Task.isCancelled { control.stop() }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            control.stop()
        }
        try Task.checkCancellation()
        guard status == 0 else { throw WhisperProcessError.failed(status, lastLine(log)) }
    }

    static func tailProgress(_ log: URL) -> Double? {
        guard let text = tail(log), let range = text.range(of: "progress =", options: .backwards) else { return nil }
        let digits = text[range.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        return Int(digits).map { min(1, Double($0) / 100) }
    }

    static func lastLine(_ log: URL) -> String {
        tail(log)?.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }

    private static func tail(_ log: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        return (try? handle.readToEnd()).flatMap { String(data: $0, encoding: .utf8) }
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var paused = false
    private var stopped = false

    init(_ process: Process) { self.process = process }

    func setPaused(_ wanted: Bool) {
        lock.withLock {
            guard process.isRunning, !stopped, wanted != paused else { return }
            paused = wanted
            if wanted { process.suspend() } else { process.resume() }
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            guard process.isRunning else { return }
            if paused { process.resume() }
            paused = false
            process.terminate()
        }
    }
}

final class WavWriter {
    let url: URL
    private let handle: FileHandle
    private var bytes: UInt32 = 0

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(count: 44))
    }

    func append(_ samples: [Float]) throws {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16((max(-1, min(1, sample)) * 32767).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        bytes += UInt32(data.count)
    }

    func finish() throws {
        func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xff) } }
        func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8)] }
        let rate = UInt32(SpeechAudio.sampleRate)
        var header = Data("RIFF".utf8)
        header += le32(36 + bytes) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        header += Data("data".utf8) + le32(bytes)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        try handle.close()
    }
}
