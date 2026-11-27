import Foundation

public struct NoteOutcome: Equatable, Sendable {
    public var generated: Bool
    public var reason: String?
    public var title: String?

    public init(generated: Bool, reason: String? = nil, title: String? = nil) {
        self.generated = generated
        self.reason = reason
        self.title = title
    }
}

public struct MeetingNoteBusy: Error, LocalizedError, Equatable {
    public init() {}

    public var errorDescription: String? { "A nota dessa reunião já está sendo gerada por outro processo." }
}

public protocol MeetingNoteWriter: Sendable {
    func writeNote(folder: URL) async throws -> NoteOutcome
}

public protocol MeetingBrainWriter: Sendable {
    func syncNote(folder: URL) async throws -> URL
}

public enum MeetingStage: Equatable, Sendable {
    case transcribing(Double)
    case refining(Double)
    case writingNote
}

public enum MeetingNoteText {
    public static func title(of markdown: String) -> String? {
        for line in markdown.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let value = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    public static func rawNote(title: String, transcript: MeetingTranscriptDocument, reason: String) -> String {
        """
        # \(title)

        > Nota não gerada: \(reason)

        ## Transcrição

        \(transcript.plainText())

        """
    }
}

public enum MeetingSpeech {
    public static let minimumSeconds = 120.0
    public static let minimumRatio = 0.05
    public static let sparseNotice = "Pouca fala detectada nesta gravação. Refiz a transcrição com mais sensibilidade; confira o texto."
    public static let silentNotice = "Quase nenhuma fala foi detectada, mesmo com a escuta mais sensível. Confira se o microfone e o áudio da chamada estavam ligados."

    public static func ratio(_ segments: [MeetingSegment], duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        var covered = 0.0
        var edge = -Double.infinity
        for segment in segments.sorted(by: { $0.start < $1.start }) where segment.end > segment.start {
            let start = max(segment.start, edge)
            if segment.end > start { covered += segment.end - start }
            edge = max(edge, segment.end)
        }
        return covered / duration
    }

    public static func isSparse(_ segments: [MeetingSegment], duration: Double) -> Bool {
        segments.isEmpty || (duration > minimumSeconds && ratio(segments, duration: duration) < minimumRatio)
    }
}

public struct MeetingPipeline: Sendable {
    public var transcriber: MeetingTranscriber
    public var notes: MeetingNoteWriter
    public var brain: MeetingBrainWriter?
    public var refiner: (@Sendable (_ language: String?) -> PostCallRefiner)?

    public init(
        transcriber: MeetingTranscriber, notes: MeetingNoteWriter, brain: MeetingBrainWriter? = nil,
        refiner: (@Sendable (_ language: String?) -> PostCallRefiner)? = nil
    ) {
        self.transcriber = transcriber
        self.notes = notes
        self.brain = brain
        self.refiner = refiner
    }

    /// Re-transcribes with Whisper at the call's language. The live transcript is kept as `transcript.parakeet.json`; any
    /// failure leaves it as the main transcript and only sets a notice, so the note still gets written.
    func refine(
        folder: URL, meta: RecordingMeta, document: MeetingTranscriptDocument, stage: @escaping @Sendable (MeetingStage) -> Void
    ) async -> MeetingTranscriptDocument {
        guard let refiner = refiner?(meta.language), refiner.engine != .off, !document.segments.isEmpty else { return document }
        stage(.refining(0))
        let result = await refiner.refine(folder: folder, meta: meta, original: document, progress: { stage(.refining($0)) })
        if let refined = result.document {
            do {
                try MeetingTranscriptFile.write(document, to: MeetingTranscriptFile.parakeetBackupURL(in: folder))
                try MeetingTranscriptFile.write(refined, in: folder)
                _ = try? RecordingFolder.update(in: folder) { $0.notice = nil }
                return refined
            } catch {
                _ = try? RecordingFolder.update(in: folder) { $0.notice = "Não consegui gravar a transcrição revisada; mantive a ao vivo." }
                return (try? MeetingTranscriptFile.read(in: folder)) ?? document
            }
        }
        if let notice = result.notice { _ = try? RecordingFolder.update(in: folder) { $0.notice = notice } }
        return document
    }

    struct LiveCheck {
        var document: MeetingTranscriptDocument?
        var sparse: Bool
        var noise: [NoiseRange] = []
    }

    func liveCheck(folder: URL, meta: RecordingMeta) -> LiveCheck {
        guard meta.status != .interrupted, var live = try? MeetingTranscriptFile.read(in: folder, live: true),
              (live.failedSegments ?? 0) == 0 else { return LiveCheck(document: nil, sparse: false) }
        guard !live.segments.isEmpty else { return LiveCheck(document: nil, sparse: true) }
        live.durationSeconds = max(live.durationSeconds, meta.durationSeconds ?? 0)
        live.segments = TranscriptTidy.mergeAdjacent(live.segments)
        if MeetingSpeech.isSparse(live.segments, duration: live.durationSeconds) { return LiveCheck(document: nil, sparse: true) }
        return LiveCheck(document: live, sparse: false, noise: live.noiseRanges ?? [])
    }

    func transcribeFinal(
        folder: URL, meta: RecordingMeta, sensitive: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (document: MeetingTranscriptDocument, notice: String?) {
        func run(_ config: ChannelStreamerConfig?) async throws -> MeetingTranscriptDocument {
            var worker = transcriber
            if let config { worker.config = config }
            return try await worker.transcribe(
                folder: folder, startedAt: meta.startedAt, sources: meta.sources ?? .both,
                duration: meta.durationSeconds ?? 0, progress: progress
            )
        }
        var document = try await run(sensitive ? .sensitive : nil)
        var raised = sensitive
        if !sensitive, MeetingSpeech.isSparse(document.segments, duration: max(document.durationSeconds, meta.durationSeconds ?? 0)) {
            let retry = try await run(.sensitive)
            raised = true
            if retry.segments.count >= document.segments.count { document = retry }
        }
        guard raised else { return (document, nil) }
        return (document, document.segments.isEmpty ? MeetingSpeech.silentNotice : MeetingSpeech.sparseNotice)
    }

    public func improveTranscript(folder: URL, stage: @escaping @Sendable (MeetingStage) -> Void = { _ in }) async throws {
        let meta = try RecordingFolder.read(in: folder)
        stage(.transcribing(0))
        let result = try await transcribeFinal(folder: folder, meta: meta, sensitive: false, progress: { stage(.transcribing($0)) })
        let document = result.document
        guard !document.segments.isEmpty else { return }
        try MeetingTranscriptFile.write(document, in: folder)
        _ = try RecordingFolder.update(in: folder) { $0.notice = result.notice }
        let refined = await refine(folder: folder, meta: try RecordingFolder.read(in: folder), document: document, stage: stage)
        stage(.writingNote)
        try await writeNote(folder: folder, document: refined, meta: try RecordingFolder.read(in: folder))
    }

    public func process(folder: URL, stage: @escaping @Sendable (MeetingStage) -> Void = { _ in }) async throws {
        var meta = try RecordingFolder.read(in: folder)
        guard meta.status != .recording else { return }
        let manager = FileManager.default
        if meta.status == .noted, manager.fileExists(atPath: RecordingFolder.noteURL(in: folder).path) { return }
        if meta.status == .transcribing || meta.status == .interrupted || !MeetingTranscriptFile.exists(in: folder) {
            do {
                stage(.transcribing(0))
                let document: MeetingTranscriptDocument
                var notice: String?
                let check = liveCheck(folder: folder, meta: meta)
                if var live = check.document {
                    if !check.noise.isEmpty {
                        let filled = try await transcriber.transcribeRanges(
                            folder: folder, ranges: check.noise, progress: { stage(.transcribing($0)) }
                        )
                        live.segments = TranscriptTidy.mergeAdjacent(live.segments + filled)
                    }
                    live.noiseRanges = nil
                    document = live
                } else {
                    let result = try await transcribeFinal(
                        folder: folder, meta: meta, sensitive: check.sparse, progress: { stage(.transcribing($0)) }
                    )
                    document = result.document
                    notice = result.notice
                }
                try MeetingTranscriptFile.write(document, in: folder)
                try? manager.removeItem(at: MeetingTranscriptFile.url(in: folder, live: true))
                meta = try RecordingFolder.update(in: folder) {
                    $0.status = .transcribed
                    $0.failure = document.segments.isEmpty ? "nenhuma fala detectada nessa gravação" : nil
                    $0.notice = notice
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                _ = try? RecordingFolder.update(in: folder) {
                    $0.status = .failed
                    $0.failure = "não consegui transcrever: \(error.localizedDescription)"
                }
                throw error
            }
        }
        var document = try MeetingTranscriptFile.read(in: folder)
        guard !document.segments.isEmpty else { return }
        if !manager.fileExists(atPath: MeetingTranscriptFile.parakeetBackupURL(in: folder).path) {
            document = await refine(folder: folder, meta: try RecordingFolder.read(in: folder), document: document, stage: stage)
            meta = try RecordingFolder.read(in: folder)
        }
        if meta.summaryDeferred == true, !manager.fileExists(atPath: RecordingFolder.noteURL(in: folder).path) {
            try await syncBrain(folder: folder)
            return
        }
        stage(.writingNote)
        try await writeNote(folder: folder, document: document, meta: meta)
    }

    public func regenerateNote(folder: URL) async throws {
        let meta = try RecordingFolder.read(in: folder)
        let document = try MeetingTranscriptFile.read(in: folder)
        try await writeNote(folder: folder, document: document, meta: meta)
    }

    private func writeNote(folder: URL, document: MeetingTranscriptDocument, meta: RecordingMeta) async throws {
        let metrics = MeetingMetricsCalculator.compute(document.segments, elapsed: document.durationSeconds).metrics
        _ = try RecordingFolder.update(in: folder) { $0.metrics = metrics }
        var outcome: NoteOutcome
        do {
            outcome = try await notes.writeNote(folder: folder)
        } catch is CancellationError {
            throw CancellationError()
        } catch let busy as MeetingNoteBusy {
            throw busy
        } catch {
            outcome = NoteOutcome(generated: false, reason: error.localizedDescription)
        }
        let noteURL = RecordingFolder.noteURL(in: folder)
        if !FileManager.default.fileExists(atPath: noteURL.path) {
            let raw = MeetingNoteText.rawNote(
                title: outcome.title ?? "Reunião", transcript: document, reason: outcome.reason ?? "o motor não devolveu a nota"
            )
            try Data(raw.utf8).write(to: noteURL, options: .atomic)
            try RecordingFolder.restrictFile(at: noteURL)
            outcome.generated = false
        }
        let title = outcome.title ?? (try? String(contentsOf: noteURL, encoding: .utf8)).flatMap(MeetingNoteText.title(of:))
        try RecordingFolder.update(in: folder) {
            $0.status = .noted
            $0.noteFile = RecordingFolder.noteFileName
            $0.noteState = outcome.generated ? .generated : .raw
            $0.title = title ?? $0.title
            $0.failure = outcome.generated ? nil : outcome.reason.map { "nota não gerada: \($0)" }
        }
        try await syncBrain(folder: folder)
    }

    private func syncBrain(folder: URL) async throws {
        guard let brain else { return }
        do {
            let saved = try await brain.syncNote(folder: folder)
            _ = try? RecordingFolder.update(in: folder) {
                $0.brainNote = saved.path
                $0.brainError = nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = try? RecordingFolder.update(in: folder) { $0.brainError = error.localizedDescription }
        }
    }
}
