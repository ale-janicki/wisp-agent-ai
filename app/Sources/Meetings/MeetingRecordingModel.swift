import Foundation
import os
import WispCore

@MainActor
final class MeetingRecordingModel: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var message: String?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var lastFolder: URL?

    private let log = Logger(subsystem: AppIdentity.bundleID, category: "meetings")
    private var recorder: MeetingRecorder?
    private var watchTask: Task<Void, Never>?

    private static let healthInterval: Duration = .seconds(1)

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase == .starting || phase == .finishing }

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: stop()
        case .starting, .finishing: break
        }
    }

    func start() {
        guard phase == .idle else { return }
        phase = .starting
        message = nil
        warnings = []
        let next = MeetingRecorder(
            mic: MicrophoneSource(), system: ProcessTapSource(), root: { [base = recordingsRoot] in base },
            makeSink: { try StereoFileSink(url: $0, container: .pcm16) }, converter: M4AFileConverter()
        )
        Task { [weak self] in
            let outcome = await Task.detached { Result { try next.start() } }.value
            self?.started(next, outcome)
        }
    }

    func stop(reason: String? = nil) {
        guard phase == .recording, let recorder else { return }
        watchTask?.cancel()
        watchTask = nil
        phase = .finishing
        startedAt = nil
        warnings = []
        Task { [weak self] in
            let outcome = await Task.detached { Result { try recorder.stop() } }.value
            self?.finished(outcome, reason: reason)
        }
    }

    func stopForQuit() {
        watchTask?.cancel()
        guard let recorder else { return }
        self.recorder = nil
        recorder.stopCaptureOnly()
    }

    func recoverInterrupted() {
        guard phase != .starting else { return }
        let base = recordingsRoot
        let active: Set<String> = phase == .idle ? [] : Set([lastFolder?.lastPathComponent].compactMap { $0 })
        Task { [weak self] in
            let found = await Task.detached {
                RecordingRecovery.recover(root: base, converter: M4AFileConverter(), excluding: active)
            }.value
            guard let self, !found.isEmpty, self.phase == .idle else { return }
            let noun = found.count == 1 ? "gravação interrompida" : "gravações interrompidas"
            self.message = "Recuperei \(found.count) \(noun) da última vez."
            self.log.info("recovered \(found.count) interrupted recordings")
        }
    }

    private var recordingsRoot: URL {
        RecordingFolder.root(configured: AppSettings.shared.settings.recordingsPath)
    }

    private func started(_ next: MeetingRecorder, _ outcome: Result<URL, any Error>) {
        switch outcome {
        case .success(let folder):
            recorder = next
            lastFolder = folder
            startedAt = Date()
            phase = .recording
            log.info("recording started")
            watch()
        case .failure(let error):
            phase = .idle
            message = error.localizedDescription
            log.error("recording refused: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finished(_ outcome: Result<RecordingResult, any Error>, reason: String?) {
        recorder = nil
        phase = .idle
        switch outcome {
        case .success(let result):
            lastFolder = result.folder
            let saved = result.failure ?? "Gravação salva em \(result.folder.lastPathComponent) (\(ElapsedFormat.clock(result.durationSeconds)))."
            message = reason.map { "A gravação parou: \($0) \(saved)" } ?? saved
            log.info("recording stopped")
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    private func watch() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.healthInterval)
                guard !Task.isCancelled, let self, let recorder = self.recorder else { return }
                let status = await Task.detached { (recorder.health(), recorder.warnings()) }.value
                guard !Task.isCancelled, self.phase == .recording else { return }
                if let issue = status.0 {
                    self.stop(reason: issue)
                    return
                }
                self.warnings = status.1.map(\.message)
            }
        }
    }
}
