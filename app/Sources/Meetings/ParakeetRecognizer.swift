import FluidAudio
import Foundation
import WispCore

final class ParakeetRecognizer: SpeechRecognizer, @unchecked Sendable {
    private static let minimumSamples = 4_800
    private static let sentenceEnd = CharacterSet(charactersIn: ".?!…")

    let engineName = "parakeet-tdt-0.6b-v3 (FluidAudio)"
    private let directory: URL
    private let loader = Loader()

    init(directory: URL) {
        self.directory = directory
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan] {
        guard samples.count >= Self.minimumSamples else { return [] }
        let manager = try await loader.manager(from: directory)
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let hint = language.flatMap(Language.init(rawValue:))
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        return Self.spans(from: result, sampleCount: samples.count)
    }

    func unload() async {
        await loader.unload()
    }

    static func spans(from result: ASRResult, sampleCount: Int) -> [RecognizedSpan] {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let whole = Double(sampleCount) / Double(SpeechAudio.sampleRate)
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            return [RecognizedSpan(text: text, start: 0, end: whole, confidence: Double(result.confidence))]
        }
        var spans: [RecognizedSpan] = []
        var piece = ""
        var first: TokenTiming?
        var confidences: [Double] = []
        func flush(until last: TokenTiming) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first, !trimmed.isEmpty {
                let mean = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
                spans.append(RecognizedSpan(text: trimmed, start: first.startTime, end: max(last.endTime, first.startTime), confidence: mean))
            }
            piece = ""
            first = nil
            confidences = []
        }
        for (index, timing) in timings.enumerated() {
            let startsWord = timing.token.hasPrefix("▁") || timing.token.hasPrefix(" ")
            if startsWord, index > 0, piece.unicodeScalars.last.map(Self.sentenceEnd.contains) == true {
                flush(until: timings[index - 1])
            }
            if first == nil { first = timing }
            piece += timing.token.replacingOccurrences(of: "▁", with: " ")
            confidences.append(Double(timing.confidence))
        }
        if let last = timings.last { flush(until: last) }
        return spans.isEmpty ? [RecognizedSpan(text: text, start: 0, end: whole, confidence: Double(result.confidence))] : spans
    }

    private actor Loader {
        private var loaded: AsrManager?

        func unload() {
            loaded = nil
        }

        func manager(from directory: URL) async throws -> AsrManager {
            if let loaded { return loaded }
            let models = try AsrModels.loadLocal(from: directory, version: .v3, encoderPrecision: .int8V2)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            loaded = manager
            return manager
        }
    }
}
