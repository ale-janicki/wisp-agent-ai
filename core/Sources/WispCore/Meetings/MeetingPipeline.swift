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

public enum MeetingStage: Equatable, Sendable {
    case transcribing(Double)
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

public struct MeetingPipeline: Sendable {
    public var transcriber: MeetingTranscriber
    public var notes: MeetingNoteWriter

    public init(transcriber: MeetingTranscriber, notes: MeetingNoteWriter) {
        self.transcriber = transcriber
        self.notes = notes
    }

    public func process(folder: URL, stage: @escaping @Sendable (MeetingStage) -> Void = { _ in }) async throws {
        var meta = try RecordingFolder.read(in: folder)
        guard meta.status != .recording else { return }
        let manager = FileManager.default
        if meta.status == .noted, manager.fileExists(atPath: RecordingFolder.noteURL(in: folder).path) { return }
        if meta.status == .transcribing || meta.status == .interrupted || !MeetingTranscriptFile.exists(in: folder) {
            do {
                stage(.transcribing(0))
                let document = try await transcriber.transcribe(
                    folder: folder, startedAt: meta.startedAt, sources: meta.sources ?? .both,
                    duration: meta.durationSeconds ?? 0, progress: { stage(.transcribing($0)) }
                )
                try MeetingTranscriptFile.write(document, in: folder)
                try? manager.removeItem(at: MeetingTranscriptFile.url(in: folder, live: true))
                meta = try RecordingFolder.update(in: folder) {
                    $0.status = .transcribed
                    $0.failure = document.segments.isEmpty ? "nenhuma fala detectada nessa gravação" : nil
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
        let document = try MeetingTranscriptFile.read(in: folder)
        guard !document.segments.isEmpty else { return }
        stage(.writingNote)
        try await writeNote(folder: folder, document: document, meta: meta)
    }

    public func regenerateNote(folder: URL) async throws {
        let meta = try RecordingFolder.read(in: folder)
        let document = try MeetingTranscriptFile.read(in: folder)
        try await writeNote(folder: folder, document: document, meta: meta)
    }

    private func writeNote(folder: URL, document: MeetingTranscriptDocument, meta: RecordingMeta) async throws {
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
    }
}
