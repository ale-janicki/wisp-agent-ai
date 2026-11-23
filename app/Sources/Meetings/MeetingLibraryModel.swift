import AppKit
import Combine
import Foundation
import os
import WispCore

struct MeetingDetail: Equatable {
    var id: String
    var lines: [TranscriptLine]
    var note: String?
}

struct WebhookOffer: Identifiable, Equatable {
    var id: String
    var title: String
    var pending: PendingWebhook
}

@MainActor
final class MeetingLibraryModel: ObservableObject {
    @Published private(set) var entries: [MeetingEntry] = []
    @Published private(set) var isLoading = true
    @Published private(set) var working: [String: MeetingStage] = [:]
    @Published private(set) var detail: MeetingDetail?
    @Published private(set) var notice: String?
    @Published private(set) var selectedID: String?
    @Published private(set) var webhookOffers: [WebhookOffer] = []

    var root: () -> URL = { RecordingFolder.defaultRoot() }
    var isRecording: @MainActor @Sendable () -> Bool = { false }
    var openInBrain: ((String) -> Void)?

    private let speech: SpeechModelModel
    private let log = Logger(subsystem: AppIdentity.bundleID, category: "meetings")
    private var queue: [URL] = []
    private var runner: Task<Void, Never>?
    private var noteTasks: [String: Task<Void, Never>] = [:]
    private var deferred: Set<String> = []
    private var reloadToken = 0
    private var janitor: Task<Void, Never>?
    private var readiness: AnyCancellable?
    private var approval = WebhookApproval()

    init(speech: SpeechModelModel) {
        self.speech = speech
        readiness = speech.$state.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] state in
            guard state == .ready else { return }
            self?.reload(thenProcess: true)
        }
    }

    var selected: MeetingEntry? { entries.first { $0.id == selectedID } }

    var rows: [MeetingRowModel] {
        entries.map { entry in
            var row = MeetingRowModel(entry: entry, working: working[entry.id] != nil)
            if row.detail == nil, MeetingLibrary.needsProcessing(entry), working[entry.id] == nil, !speech.isReady {
                row.detail = "Baixe o modelo de transcrição para continuar."
            }
            return row
        }
    }

    func stage(of id: String) -> MeetingStage? { working[id] }

    func select(_ id: String?) {
        selectedID = id
        loadDetail()
    }

    func reload(select id: String? = nil, thenProcess: Bool = false) {
        reloadToken += 1
        let token = reloadToken
        let base = root()
        Task { [weak self] in
            let listed = await Task.detached { MeetingLibrary.list(root: base) }.value
            guard let self, token == self.reloadToken else { return }
            self.entries = listed
            self.isLoading = false
            if let id { self.selectedID = id }
            if let current = self.selectedID, !listed.contains(where: { $0.id == current }) { self.selectedID = nil }
            self.loadDetail()
            if thenProcess { self.processPending() }
        }
    }

    /// Moves meetings already saved in the brain to the Trash once they are older than the configured days: a few seconds
    /// after launch, then every 24 h. Skips what is being recorded, processed or open.
    func startJanitor() {
        guard janitor == nil else { return }
        janitor = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.sweepOldRecordings()
                try? await Task.sleep(for: .seconds(86_400))
            }
        }
    }

    private func sweepOldRecordings() async {
        let days = AppSettings.shared.settings.meetings.cleanupDays
        guard days > 0, !isRecording() else { return }
        let roots = PathsModel.shared.recordingRoots()
        let busy: @Sendable (String) async -> Bool = { [weak self] id in
            await MainActor.run { self?.isBusy(id) ?? true }
        }
        let result = await Task.detached(priority: .utility) {
            await MeetingJanitor.run(roots: roots, days: days, isExcluded: busy) { folder in
                try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            }
        }.value
        guard result.removed > 0 || result.failed > 0 else { return }
        log.info("cleanup: \(result.removed, privacy: .public) moved to Trash, \(result.failed, privacy: .public) failed")
        if result.removed > 0 { reload() }
    }

    /// Live check right before a folder is touched: recording, processing, queued or open.
    private func isBusy(_ id: String) -> Bool {
        isRecording() || working[id] != nil || queue.contains { $0.lastPathComponent == id } || selectedID == id
    }

    func processPending() {
        guard speech.isReady else { return }
        for entry in entries where MeetingLibrary.needsProcessing(entry) { enqueue(entry.folder) }
    }

    func retry(_ entry: MeetingEntry) {
        guard entry.meta.status == .failed else { return }
        let folder = entry.folder
        Task { [weak self] in
            let hasAudio = StereoAudioReader.audioURL(in: folder) != nil
            let hasTranscript = MeetingTranscriptFile.exists(in: folder)
            _ = try? RecordingFolder.update(in: folder) {
                $0.status = hasTranscript ? .transcribed : .transcribing
                $0.failure = hasAudio || hasTranscript ? nil : $0.failure
            }
            self?.reload(thenProcess: hasAudio || hasTranscript)
        }
    }

    func regenerateNote(_ entry: MeetingEntry) {
        guard working[entry.id] == nil, speech.isReady || entry.hasTranscript else { return }
        let folder = entry.folder
        let id = entry.id
        working[id] = .writingNote
        deferred.remove(id)
        noteTasks[id] = Task { [weak self] in
            do {
                try await self?.makePipeline()?.regenerateNote(folder: folder)
            } catch is CancellationError {
                self?.notice = "Geração da nota cancelada."
            } catch {
                self?.notice = "Não consegui gerar a nota: \(error.localizedDescription)"
            }
            self?.working[id] = nil
            self?.noteTasks[id] = nil
            await self?.speech.releaseFinal()
            self?.reload()
        }
    }

    func improveTranscript(_ entry: MeetingEntry) {
        guard working[entry.id] == nil, speech.isReady, !isRecording() else { return }
        let folder = entry.folder
        let id = entry.id
        working[id] = .transcribing(0)
        let publish: @Sendable (MeetingStage) -> Void = { [weak self] stage in
            Task { @MainActor in self?.working[id] = stage }
        }
        noteTasks[id] = Task(priority: .utility) { [weak self] in
            do {
                try await self?.makePipeline()?.improveTranscript(folder: folder, stage: publish)
            } catch is CancellationError {
                self?.notice = "Transcrição cancelada."
            } catch {
                self?.notice = "Não consegui melhorar a transcrição: \(error.localizedDescription)"
            }
            self?.working[id] = nil
            self?.noteTasks[id] = nil
            await self?.speech.releaseFinal()
            self?.reload()
        }
    }

    static func brainRoot() -> String {
        let profile = try? ProfileLoader.load(from: ConversationViewModel.profileURL)
        return MeetingBrainRoot.resolve(
            profileRoot: profile?.blocks?.memory?.root, configured: PathsModel.shared.url(.brain).path)
    }

    func openNote(_ entry: MeetingEntry) {
        guard brainButton(entry).opensNote, let path = entry.meta.brainNote else { return }
        if let openInBrain {
            openInBrain(path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    func reveal(_ entry: MeetingEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
    }

    func copy(_ entry: MeetingEntry) {
        let text = detail?.id == entry.id ? (detail?.note ?? Self.plain(detail?.lines ?? [])) : ""
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = entry.hasNote ? "Nota copiada." : "Transcrição copiada."
    }

    func brainButton(_ entry: MeetingEntry) -> MeetingBrainButton {
        let path = entry.meta.brainNote
        return MeetingBrainButton.make(brainNote: path, exists: path.map { FileManager.default.fileExists(atPath: $0) } ?? false)
    }

    func brainAction(_ entry: MeetingEntry) {
        if brainButton(entry).opensNote {
            openNote(entry)
        } else {
            syncToBrain(entry)
        }
    }

    private func syncToBrain(_ entry: MeetingEntry) {
        guard entry.hasTranscript || entry.hasNote else { return }
        let folder = entry.folder
        let layout = RuntimeLayout(bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
        let writer = WispBrainWriter(layout: layout, brain: Self.brainRoot(), recreate: true)
        Task { [weak self] in
            do {
                let saved = try await writer.syncNote(folder: folder)
                _ = try? RecordingFolder.update(in: folder) {
                    $0.brainNote = saved.path
                    $0.brainError = nil
                }
                self?.notice = "Salvo no brain: meetings/\(saved.lastPathComponent)"
            } catch {
                _ = try? RecordingFolder.update(in: folder) { $0.brainError = error.localizedDescription }
                self?.notice = "Não consegui salvar no brain: \(error.localizedDescription)"
            }
            self?.reload()
        }
    }

    func cancelProcessing() {
        runner?.cancel()
        noteTasks.values.forEach { $0.cancel() }
    }

    func cancelNote(_ id: String) {
        if let task = noteTasks[id] { task.cancel() } else { runner?.cancel() }
    }

    func dismissNotice() { notice = nil }

    func allowWebhook(_ id: String) {
        let approved = approval.approve(id)
        let title = webhookOffers.first { $0.id == id }?.title ?? id
        webhookOffers.removeAll { $0.id == id }
        let folder = root().appendingPathComponent(id, isDirectory: true)
        Task { [weak self] in
            do {
                let sent = try await WebhookDelivery.deliver(approved, via: MeetingWebhookSender.send)
                guard sent, let approved else { return }
                _ = try? RecordingFolder.update(in: folder) { $0.webhookSentAt = Date() }
                self?.notice = "Enviei \"\(title)\" para \(approved.host)."
            } catch {
                self?.notice = "Não consegui enviar para o webhook: \(error.localizedDescription)"
            }
        }
    }

    func dismissWebhook(_ id: String) {
        approval.dismiss(id)
        webhookOffers.removeAll { $0.id == id }
    }

    private func offerWebhook(folder: URL) async {
        let settings = AppSettings.shared.settings.meetings
        guard settings.webhookEnabled else { return }
        let id = folder.lastPathComponent
        guard !webhookOffers.contains(where: { $0.id == id }) else { return }
        let prepared = await Task.detached { () -> Result<WebhookOffer?, any Error> in
            Result {
                let meta = try RecordingFolder.read(in: folder)
                guard meta.noteState == .generated, meta.webhookSentAt == nil else { return nil }
                let target = try MeetingWebhook.validate(WebhookKeychain.load(.url) ?? "")
                let note = try String(contentsOf: RecordingFolder.noteURL(in: folder), encoding: .utf8)
                let title = meta.title ?? MeetingRowModel.defaultTitle(meta.startedAt)
                let content = try MeetingWebhook.content(
                    title: title, startedAt: meta.startedAt, durationSeconds: meta.durationSeconds ?? 0, note: note, metrics: meta.metrics
                )
                if settings.webhookSigns, WebhookKeychain.load(.secret) == nil { throw WebhookError.invalid }
                return WebhookOffer(id: id, title: title, pending: PendingWebhook(target: target, body: content.body, preview: content.preview, signed: settings.webhookSigns))
            }
        }.value
        switch prepared {
        case .success(let offer?):
            approval.offer(offer.pending, for: id)
            webhookOffers.append(offer)
        case .success(nil):
            break
        case .failure(let error):
            notice = "Não ofereci o envio do webhook: \(error.localizedDescription)"
        }
    }

    private func enqueue(_ folder: URL) {
        let id = folder.lastPathComponent
        guard working[id] == nil, !queue.contains(folder), !deferred.contains(id) else { return }
        queue.append(folder)
        working[id] = .transcribing(0)
        if runner == nil { runner = Task(priority: .utility) { [weak self] in await self?.drain() } }
    }

    private func drain() async {
        let publish: @Sendable (String, MeetingStage) -> Void = { [weak self] id, stage in
            Task { @MainActor in self?.working[id] = stage }
        }
        while !queue.isEmpty {
            let folder = queue.removeFirst()
            let id = folder.lastPathComponent
            do {
                while isRecording() { try await Task.sleep(for: .seconds(2)) }
            } catch {
                queue.removeAll()
                working = [:]
                break
            }
            guard let pipeline = makePipeline() else {
                working[id] = nil
                continue
            }
            let gate = StageGate()
            do {
                try await pipeline.process(folder: folder, stage: { stage in
                    guard gate.allow(stage) else { return }
                    publish(id, stage)
                })
                await offerWebhook(folder: folder)
            } catch is CancellationError {
            } catch is MeetingNoteBusy {
                deferred.insert(id)
                notice = MeetingNoteBusy().localizedDescription
            } catch {
                log.error("pipeline failed: \(error.localizedDescription, privacy: .public)")
                notice = "Não consegui transcrever \(id): \(error.localizedDescription)"
            }
            working[id] = nil
            reload()
        }
        runner = nil
        await speech.releaseFinal()
    }

    private func makePipeline() -> MeetingPipeline? {
        guard let recognizer = speech.finalRecognizer() else { return nil }
        let layout = RuntimeLayout(bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
        let recording = isRecording
        let gate = MeetingPauseGate(recognizer: recognizer, isRecording: { await recording() })
        let pause: @Sendable () async throws -> Void = { try await gate.wait() }
        return MeetingPipeline(
            transcriber: MeetingTranscriber(recognizer: recognizer, pause: pause), notes: WispNoteWriter(layout: layout),
            brain: WispBrainWriter(layout: layout, brain: Self.brainRoot())
        )
    }

    private func loadDetail() {
        guard let entry = selected else {
            detail = nil
            return
        }
        let folder = entry.folder
        let id = entry.id
        Task { [weak self] in
            let loaded = await Task.detached { () -> MeetingDetail in
                let document = (try? MeetingTranscriptFile.read(in: folder)) ?? (try? MeetingTranscriptFile.read(in: folder, live: true))
                let note = try? String(contentsOf: RecordingFolder.noteURL(in: folder), encoding: .utf8)
                return MeetingDetail(id: id, lines: TranscriptLine.lines(document?.segments ?? []), note: note)
            }.value
            guard let self, self.selectedID == id else { return }
            self.detail = loaded
        }
    }

    private static func plain(_ lines: [TranscriptLine]) -> String {
        lines.map { "[\($0.time)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }
}

private final class StageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func allow(_ stage: MeetingStage) -> Bool {
        lock.withLock {
            let key: Int
            switch stage {
            case .transcribing(let fraction): key = Int(fraction * 100)
            case .writingNote: key = 1000
            }
            guard key != last else { return false }
            last = key
            return true
        }
    }
}
