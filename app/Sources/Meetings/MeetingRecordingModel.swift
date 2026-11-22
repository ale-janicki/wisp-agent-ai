import AVFoundation
import Foundation
import os
import WispCore

struct MeetingEventContext: Sendable {
    let event: CalEvent
    let calendarTitle: String?
    let links: EventLinkStore
}

@MainActor
final class MeetingRecordingModel: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var message: String?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var lastFolder: URL?
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var liveLines: [TranscriptLine] = []
    @Published private(set) var liveNotice: String?
    @Published private(set) var micPermission: PermissionState = .unknown
    @Published private(set) var systemPermission: PermissionState
    @Published private(set) var liveLagging = false
    @Published private(set) var systemSilent = false
    @Published var sources: RecordingSources {
        didSet { defaults.set(sources.rawValue, forKey: Self.sourcesKey) }
    }

    let speech = SpeechModelModel()
    let library: MeetingLibraryModel

    private static let sourcesKey = "meetings.sources"
    private static let systemKey = "meetings.systemAudioPermission"
    private static let levelInterval: Duration = .milliseconds(100)
    private static let healthEvery = 10

    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: AppIdentity.bundleID, category: "meetings")
    private var recorder: MeetingRecorder?
    private var watchTask: Task<Void, Never>?
    private var live: LiveTranscriber?
    private let bridge = LiveBridge()
    private var recordingSources: RecordingSources = .both
    private var systemWatch = SystemAudioWatch()
    private var pendingLink: MeetingEventContext?

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase == .starting || phase == .finishing }

    var control: RecordControl {
        RecordControl(phase: controlPhase, elapsed: startedAt.map { Date().timeIntervalSince($0) } ?? 0, canRecord: true)
    }

    var permissionCards: [PermissionCard] {
        MeetingPermissions.cards(mic: micPermission, system: systemPermission, sources: sources)
    }

    var silenceCard: PermissionCard? {
        MeetingPermissions.silenceHint(sources: sources, silent: systemSilent && isRecording)
    }

    var permissionHint: String? {
        MeetingPermissions.hint(mic: micPermission, system: systemPermission, sources: sources)
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.sourcesKey).flatMap(RecordingSources.init(rawValue:))
        sources = stored ?? .both
        systemWatch = SystemAudioWatch(stored: Self.storedSystemPermission())
        systemPermission = systemWatch.state
        library = MeetingLibraryModel(speech: speech)
        library.root = { [weak self] in self?.recordingsRoot ?? RecordingFolder.defaultRoot() }
        library.isRecording = { [weak self] in self?.phase != .idle }
        refreshPermissions()
    }

    func refreshPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micPermission = .granted
        case .notDetermined: micPermission = .notDetermined
        default: micPermission = .denied
        }
    }

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: stop()
        case .starting, .finishing: break
        }
    }

    func start(linkedTo context: MeetingEventContext? = nil) {
        guard phase == .idle else { return }
        pendingLink = context
        phase = .starting
        message = nil
        warnings = []
        liveLines = []
        liveNotice = nil
        liveLagging = false
        systemWatch.startRecording()
        systemSilent = false
        micLevel = 0
        systemLevel = 0
        let chosen = sources
        recordingSources = chosen
        let now = Date()
        let bridge = bridge
        let next = MeetingRecorder(
            mic: MicrophoneSource(), system: ProcessTapSource(), root: { [base = recordingsRoot] in base },
            makeSink: { try StereoFileSink(url: $0, container: .pcm16) }, converter: M4AFileConverter(),
            sources: chosen, onAudio: { bridge.push($1, channel: $0, time: $2) }
        )
        Task { [weak self] in
            let outcome = await Task.detached { Result { try next.start(now: now) } }.value
            self?.started(next, outcome, startedAt: now)
        }
    }

    func stop(reason: String? = nil) {
        guard phase == .recording, let recorder else { return }
        watchTask?.cancel()
        watchTask = nil
        phase = .finishing
        startedAt = nil
        warnings = []
        micLevel = 0
        systemLevel = 0
        bridge.detach()
        let ending = live
        live = nil
        liveLagging = false
        systemWatch.startRecording()
        systemSilent = false
        Task { [weak self] in
            let outcome = await Task.detached { Result { try recorder.stop() } }.value
            await ending?.stopAndWait()
            self?.finished(outcome, reason: reason)
        }
    }

    func stopForQuit() {
        watchTask?.cancel()
        bridge.detach()
        live?.cancel()
        library.cancelProcessing()
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
            guard let self else { return }
            self.speech.refresh()
            self.library.reload(thenProcess: true)
            guard !found.isEmpty, self.phase == .idle else { return }
            let noun = found.count == 1 ? "gravação interrompida" : "gravações interrompidas"
            self.message = "Recuperei \(found.count) \(noun) da última vez e vou transcrever."
            self.log.info("recovered \(found.count) interrupted recordings")
        }
    }

    private var controlPhase: RecordControl.Phase {
        switch phase {
        case .idle: .idle
        case .starting: .starting
        case .recording: .recording
        case .finishing: .finishing
        }
    }

    private var recordingsRoot: URL {
        RecordingFolder.root(configured: AppSettings.shared.settings.recordingsPath)
    }

    private func started(_ next: MeetingRecorder, _ outcome: Result<URL, any Error>, startedAt now: Date) {
        switch outcome {
        case .success(let folder):
            recorder = next
            lastFolder = folder
            if let context = pendingLink {
                if (try? context.links.recordRecording(event: context.event, calendarTitle: context.calendarTitle, folder: folder)) == nil {
                    log.error("could not link recording to event")
                }
                pendingLink = nil
            }
            startedAt = now
            phase = .recording
            library.select(nil)
            log.info("recording started")
            startLive(folder: folder, startedAt: now)
            watch()
        case .failure(let error):
            phase = .idle
            pendingLink = nil
            message = error.localizedDescription
            refreshPermissions()
            log.error("recording refused: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startLive(folder: URL, startedAt now: Date) {
        speech.refresh()
        guard let recognizer = speech.liveRecognizer() else {
            liveNotice = "O modelo de transcrição ainda não está baixado. A gravação segue e eu transcrevo quando ele estiver pronto."
            return
        }
        let store = MeetingTranscriptStore(startedAt: now, engine: recognizer.engineName, folder: folder)
        let channels: Set<AudioChannel> = Set(AudioChannel.allCases.filter {
            $0 == .mic ? recordingSources.usesMic : recordingSources.usesSystem
        })
        let transcriber = LiveTranscriber(
            recognizer: recognizer, store: store, channels: channels,
            onUpdate: { [weak self] segments in
                let lines = TranscriptLine.lines(segments)
                Task { @MainActor in self?.liveLines = lines }
            },
            onFailure: { [weak self] reason in
                Task { @MainActor in self?.liveNotice = "A transcrição ao vivo falhou (\(reason)). Eu refaço quando você parar." }
            },
            onLag: { [weak self] behind in
                Task { @MainActor in self?.liveLagging = behind }
            }
        )
        live = transcriber
        bridge.attach(transcriber)
    }

    private func finished(_ outcome: Result<RecordingResult, any Error>, reason: String?) {
        recorder = nil
        phase = .idle
        refreshPermissions()
        switch outcome {
        case .success(let result):
            lastFolder = result.folder
            let saved = result.failure ?? "Gravação salva em \(result.folder.lastPathComponent) (\(ElapsedFormat.clock(result.durationSeconds)))."
            message = reason.map { "A gravação parou: \($0) \(saved)" } ?? saved
            log.info("recording stopped")
            let folder = result.folder.lastPathComponent
            let process = result.failure == nil
            Task { [weak self] in
                await self?.speech.releaseLive()
                self?.library.reload(select: folder, thenProcess: process)
            }
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    private func watch() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.levelInterval)
                tick += 1
                guard !Task.isCancelled, let self, let recorder = self.recorder else { return }
                let levels = await Task.detached { recorder.levels() }.value
                guard !Task.isCancelled, self.phase == .recording else { return }
                self.micLevel = levels.mic
                self.systemLevel = levels.system
                guard tick % Self.healthEvery == 0 else { continue }
                let status = await Task.detached { (recorder.health(), recorder.warnings()) }.value
                guard !Task.isCancelled, self.phase == .recording else { return }
                if let issue = status.0 {
                    self.stop(reason: issue)
                    return
                }
                self.warnings = status.1.map(\.message)
                if self.recordingSources.usesSystem {
                    self.systemWatch.observe(level: levels.system, silentWarning: status.1.contains(.systemSilent))
                    self.syncSystemPermission()
                }
            }
        }
    }

    private func syncSystemPermission() {
        if systemPermission != systemWatch.state { systemPermission = systemWatch.state }
        if systemSilent != systemWatch.silentNow { systemSilent = systemWatch.silentNow }
        if systemWatch.shouldPersist { defaults.set("granted", forKey: Self.systemKey) }
    }

    private static func storedSystemPermission() -> PermissionState {
        switch UserDefaults.standard.string(forKey: systemKey) {
        case "granted": .granted
        default: .unknown
        }
    }
}

private final class LiveBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var target: LiveTranscriber?

    private var aligner = LiveAudioAligner()

    func attach(_ transcriber: LiveTranscriber) {
        lock.withLock {
            aligner = LiveAudioAligner()
            target = transcriber
        }
    }

    func detach() { lock.withLock { target = nil } }

    func push(_ samples: [Float], channel: AudioChannel, time: Double) {
        let current = lock.withLock { (target, aligner) }
        guard let transcriber = current.0 else { return }
        let chunk = current.1.align(samples, channel: channel, at: time)
        if let gap = chunk.gapSeconds { transcriber.skipGap(seconds: gap, channel: channel) }
        transcriber.push48k(chunk.samples, channel: channel)
    }
}
