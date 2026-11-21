import AppKit
import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class ConversationViewModel {
    enum Onboarding: Equatable {
        case claudeMissing
        case authRequired
    }

    private(set) var records: [ConversationRecord] = []
    private(set) var onboarding: Onboarding?
    private(set) var profileError: String?
    private(set) var profile: Profile = .default
    private(set) var rateLimit: RateLimit?
    let telegram = TelegramModel()
    private(set) var pendingAttachments: [URL] = []
    private(set) var attachmentNotice: String?
    private(set) var sharingSession: String?
    var isSharing: Bool { sharingSession != nil }
    private(set) var tailPreviews: [String: String] = [:]
    private(set) var current = ConversationRuntime()
    private(set) var runtimes: [UUID: ConversationRuntime] = [:]

    @ObservationIgnored weak var shell: ShellController? {
        didSet {
            shell?.restTarget = { [weak self] in self?.restTarget() ?? .rest }
        }
    }
    @ObservationIgnored private let store: ConversationStore
    @ObservationIgnored let sessionLock: SessionLock
    @ObservationIgnored private var tailsLoading: Set<String> = []
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "conversation")
    @ObservationIgnored private var restTask: Task<Void, Never>?
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private var demoAsk2: String?
    @ObservationIgnored private var demoRetry: String?
    #endif

    private static let titleLimit = 40
    private static let pillBodyLimit = 60
    private static let transientDuration: Duration = .seconds(4)
    private static let sweepInterval: Duration = .seconds(60)
    private static let attachmentLimit = 10
    private static let attachmentOrigin = "Wisp"
    static let waitingStep = "Respondendo pelo Telegram…"

    nonisolated private static let debugProfile: URL? = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-WispProfile"), args.indices.contains(index + 1) {
            return URL(fileURLWithPath: args[index + 1])
        }
        #endif
        return nil
    }()

    nonisolated static var profileURL: URL { debugProfile ?? ProfileLoader.defaultURL }

    nonisolated static var dataDirectory: URL {
        debugProfile.map { $0.deletingLastPathComponent().appendingPathComponent("data", isDirectory: true) }
            ?? ConversationStore.defaultDirectory
    }

    var personaName: String { profile.persona.name }

    var state: ConversationState { current.state }
    var currentId: UUID { current.id }
    var currentTitle: String? { current.title }
    var isLoadingHistory: Bool { current.isLoadingHistory }
    var waitingForTelegram: Bool { current.waitingForTelegram }
    var telegramNotice: String? { current.telegramNotice }
    var isThinking: Bool { current.isThinking }
    var isFailed: Bool { current.isFailed }
    private var turnRunning: Bool { current.turnRunning }

    var linkedThread: Int? { current.linkedThread }

    init(
        store: ConversationStore = ConversationStore(directory: ConversationViewModel.dataDirectory),
        sessionLock: SessionLock = SessionLock()
    ) {
        self.store = store
        self.sessionLock = sessionLock
        records = store.all()
        adopt(current)
        if let note = store.lastRecoveryNote { current.appendSystem(note) }
        loadProfile()
        probeClaude()
        Task { [weak self] in await self?.refreshTelegram() }
        PermissionModel.shared.onChange = { [weak self] in self?.permissionModeChanged() }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sweepInterval)
                self?.runtimeSettled()
            }
        }
    }

    var sections: ConversationSections {
        TelegramTopics.sections(records: records, topics: telegram.loadedTopics, order: AppSettings.shared.settings.telegramOrder)
    }

    // MARK: Last-message preview

    private static func previewKey(sessionId: String, stamp: Date?) -> String {
        "\(sessionId)|\(stamp?.timeIntervalSince1970 ?? 0)"
    }

    func preview(_ record: ConversationRecord) -> String? {
        if let stored = ConversationPreview.display(record.lastPreview, from: record.lastFrom) { return stored }
        guard let sessionId = record.sessionId else { return nil }
        return tailPreviews[Self.previewKey(sessionId: sessionId, stamp: record.updatedAt)].flatMap { $0.isEmpty ? nil : $0 }
    }

    func preview(_ entry: TelegramEntry) -> String? {
        let topic = entry.topic
        if let record = entry.record, record.updatedAt >= (topic.lastUsed ?? .distantPast),
           let stored = ConversationPreview.display(record.lastPreview, from: record.lastFrom) {
            return stored
        }
        return tailPreviews[Self.previewKey(sessionId: topic.sessionId, stamp: topic.lastUsed)].flatMap { $0.isEmpty ? nil : $0 }
    }

    func fillPreviews() {
        let sections = self.sections
        struct Job { let key: String; let sessionId: String; let cwd: String }
        var jobs: [Job] = []
        for record in sections.wisp where record.lastPreview == nil {
            guard let sessionId = record.sessionId else { continue }
            jobs.append(Job(key: Self.previewKey(sessionId: sessionId, stamp: record.updatedAt), sessionId: sessionId,
                            cwd: expandTilde(record.cwd ?? profile.agent.cwd)))
        }
        for entry in sections.telegram {
            if let record = entry.record, record.updatedAt >= (entry.topic.lastUsed ?? .distantPast), record.lastPreview != nil { continue }
            jobs.append(Job(key: Self.previewKey(sessionId: entry.topic.sessionId, stamp: entry.topic.lastUsed),
                            sessionId: entry.topic.sessionId, cwd: expandTilde(entry.topic.cwd)))
        }
        let prefix = profile.agent.statusPrefix
        for job in jobs where tailPreviews[job.key] == nil && tailsLoading.insert(job.key).inserted {
            Task { [weak self] in
                let found = await Task.detached(priority: .utility) {
                    ConversationPreview.load(sessionId: job.sessionId, cwd: job.cwd, statusPrefix: prefix, telegramHTML: true)
                }.value
                guard let self else { return }
                self.tailsLoading.remove(job.key)
                self.tailPreviews[job.key] = found.flatMap { ConversationPreview.display($0.text, from: $0.from) } ?? ""
            }
        }
    }

    // MARK: Onboarding

    private func loadProfile() {
        do {
            profile = try ProfileLoader.load(from: Self.profileURL)
            profileError = nil
            telegram.configure(profile.blocks?.telegram)
        } catch {
            profileError = error.localizedDescription
        }
    }

    func reloadProfile() {
        loadProfile()
        Task { [weak self] in await self?.refreshTelegram() }
    }

    private func probeClaude() {
        let configured = profile.agent.claudePath
        Task { [weak self] in
            let found = await Task.detached { (try? ClaudeLocator.resolve(configured: configured)) != nil }.value
            guard let self, !found else { return }
            self.onboarding = .claudeMissing
        }
    }

    func recheck() {
        loadProfile()
        let configured = profile.agent.claudePath
        Task { [weak self] in
            let found = await Task.detached { (try? ClaudeLocator.resolve(configured: configured)) != nil }.value
            guard let self else { return }
            if found {
                self.onboarding = nil
                if self.isFailed { self.retry() }
            } else {
                self.onboarding = .claudeMissing
            }
        }
    }

    // MARK: Actions

    var inputBlocked: Bool { profileError != nil || onboarding != nil }

    func attach(_ urls: [URL]) {
        let checked = AttachmentStaging.regularFiles(urls.filter(\.isFileURL))
        let files = checked.files.filter { !pendingAttachments.contains($0) }
        pendingAttachments = Array((pendingAttachments + files).prefix(Self.attachmentLimit))
        attachmentNotice = checked.refused.isEmpty ? nil : AttachmentStaging.refusal(checked.refused)
    }

    func detach(_ url: URL) {
        pendingAttachments.removeAll { $0 == url }
        attachmentNotice = nil
    }

    private var attachmentsRoot: URL {
        if let folder = profile.blocks?.telegram?.attachments, !folder.isEmpty {
            return URL(fileURLWithPath: expandTilde(folder), isDirectory: true)
        }
        return WispFolder.layout().anexos
    }

    private func deleteStaged(_ paths: [String]) {
        let root = attachmentsRoot.standardizedFileURL.path + "/"
        for path in paths where URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    @discardableResult
    func send(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty, !inputBlocked else { return false }
        guard !pendingAttachments.isEmpty else { return submit(prompt: text, caption: text, files: []) }
        do {
            let staged = try AttachmentStaging.stage(pendingAttachments, into: attachmentsRoot)
            let prompt = MessageAttachments.compose(origin: Self.attachmentOrigin, files: staged, caption: text, user: profile.persona.user)
            guard submit(prompt: prompt, caption: text, files: staged.map(\.path)) else {
                deleteStaged(staged.map(\.path))
                return false
            }
            pendingAttachments = []
            attachmentNotice = nil
            return true
        } catch {
            attachmentNotice = "Não consegui preparar o anexo: \(error.localizedDescription)"
            return false
        }
    }

    private func submit(prompt text: String, caption: String, files: [String]) -> Bool {
        current.submit(prompt: text, caption: caption)
        return true
    }

    func retry() {
        current.retry()
    }

    func newConversation() {
        let next = ConversationRuntime()
        adopt(next)
        activate(next)
    }

    func delete(_ record: ConversationRecord) {
        do {
            try store.delete(id: record.id)
        } catch {
            log.error("conversation delete failed: \(error.localizedDescription, privacy: .public)")
            current.appendSystem("não consegui apagar a conversa: \(error.localizedDescription)")
            return
        }
        records = store.all()
        if let runtime = runtimes[record.id] {
            runtime.shutdown()
            runtimes[record.id] = nil
        }
        if record.id == currentId { newConversation() }
    }

    func open(_ record: ConversationRecord) {
        if let existing = runtime(id: record.id, sessionId: record.sessionId) {
            activate(existing)
            return
        }
        if let topic = TelegramTopics.topic(forSession: record.sessionId, in: telegram.loadedTopics) {
            openLinked(topic: topic, title: record.title, id: record.id)
            return
        }
        let next = ConversationRuntime(id: record.id, title: record.title, cwd: record.cwd, sessionId: record.sessionId, titleGenerated: record.titleGenerated, awayOnPhone: record.awayOnPhone)
        adopt(next)
        activate(next)
        next.loadHistory(of: record)
    }

    func openConversation(id: UUID) {
        guard id != currentId else { return }
        if let existing = runtimes[id] {
            activate(existing)
        } else if let record = records.first(where: { $0.id == id }) {
            open(record)
        }
    }

    var approvalQueue: [PermissionRequest] { state.approvals }

    func answer(_ request: PermissionRequest, _ decision: PermissionDecision) {
        current.answer(request, decision)
    }

    // MARK: Runtimes

    private func adopt(_ runtime: ConversationRuntime) {
        runtime.host = self
        runtimes[runtime.id] = runtime
    }

    private func runtime(id: UUID, sessionId: String?) -> ConversationRuntime? {
        if let byId = runtimes[id] { return byId }
        guard let sessionId else { return nil }
        return runtimes.values.first { $0.state.sessionId == sessionId }
    }

    private func activate(_ runtime: ConversationRuntime) {
        current = runtime
        runtime.unseenReply = false
        runtime.telegramNotice = nil
        runtime.touch()
        syncPill()
        runtimeSettled()
    }

    func isCurrent(_ runtime: ConversationRuntime) -> Bool { runtime === current }

    func runtimeSettled() {
        let all = runtimes.values.map { $0.snapshot(isCurrent: $0 === current) }
        for id in RuntimeLifecycle.processesToStop(all, now: Date()) { runtimes[id]?.stopIdleProcess() }
        let remaining = runtimes.values.map { $0.snapshot(isCurrent: $0 === current) }
        for id in RuntimeLifecycle.runtimesToDrop(remaining) {
            runtimes[id]?.shutdown()
            runtimes[id] = nil
        }
    }

    func activity(id: UUID?, sessionId: String?) -> RowActivity {
        let found = id.flatMap { runtimes[$0] }
            ?? sessionId.flatMap { sid in runtimes.values.first { $0.state.sessionId == sid } }
        let sharing = sharingSession != nil && (sessionId ?? found?.state.sessionId) == sharingSession
        guard let runtime = found else { return sharing ? .sharing : .none }
        return RowActivity.of(
            isCurrent: runtime === current,
            isThinking: runtime.isThinking,
            hasApproval: !runtime.state.approvals.isEmpty,
            hasUnseenReply: runtime.unseenReply,
            isSharing: sharing
        )
    }

    func setOnboarding(_ value: Onboarding?) { onboarding = value }

    func setRateLimit(_ value: RateLimit?) { rateLimit = value }

    func save(_ record: ConversationRecord) throws {
        try store.upsert(record)
        records = store.all()
    }

    // MARK: Telegram

    func refreshTelegram() async {
        await telegram.refresh()
        fillPreviews()
        shell?.notices.topicsLoaded(telegram.loadedTopics, following: linkedThread, records: records, statusPrefix: profile.agent.statusPrefix)
        syncFollowing()
    }

    func open(_ entry: TelegramEntry) {
        let id = entry.record?.id ?? UUID()
        if let existing = runtime(id: id, sessionId: entry.topic.sessionId) {
            activate(existing)
            return
        }
        openLinked(topic: entry.topic, title: entry.record?.title ?? entry.topic.name, id: id)
    }

    func close(_ entry: TelegramEntry) {
        let thread = entry.topic.thread
        Task { [weak self] in
            guard let self else { return }
            await self.telegram.close(thread: thread)
            self.syncFollowing()
        }
    }

    private func openLinked(topic: TelegramTopic, title: String, id: UUID) {
        let away = records.first { $0.id == id }?.awayOnPhone ?? false
        let next = ConversationRuntime(id: id, title: title, cwd: topic.cwd, sessionId: topic.sessionId, awayOnPhone: away)
        adopt(next)
        activate(next)
        next.startLinked(sessionId: topic.sessionId, cwd: topic.cwd)
    }

    private func syncFollowing() {
        for runtime in runtimes.values { runtime.syncFollowing() }
    }

    // MARK: Share

    func canShare(_ record: ConversationRecord) -> Bool {
        guard telegram.canShare, !isSharing, record.sessionId != nil else { return false }
        return !(runtimes[record.id]?.turnRunning ?? false)
    }

    var canShareCurrent: Bool {
        telegram.canShare && !isSharing && state.sessionId != nil && !turnRunning && linkedThread == nil
    }

    func share(_ record: ConversationRecord) {
        guard canShare(record), let sessionId = record.sessionId else { return }
        share(sessionId: sessionId, cwd: record.cwd ?? profile.agent.cwd, name: record.title)
    }

    func shareCurrent() {
        guard canShareCurrent, let sessionId = state.sessionId else { return }
        share(sessionId: sessionId, cwd: current.cwd ?? profile.agent.cwd, name: currentTitle ?? "Conversa")
    }

    private func share(sessionId: String, cwd: String, name: String) {
        sharingSession = sessionId
        let runtime = current
        runtime.telegramNotice = nil
        Task { [weak self] in
            guard let self else { return }
            let result = await self.telegram.share(
                session: sessionId, cwd: expandTilde(cwd), name: String(name.prefix(Self.titleLimit)))
            switch result {
            case .success: await self.refreshTelegram()
            case .failure(let failure): runtime.telegramNotice = failure.sentence
            }
            self.sharingSession = nil
        }
    }

    // MARK: Phone mode

    var canContinueOnPhoneCurrent: Bool {
        telegram.canShare && telegram.canPost && !isSharing && state.sessionId != nil && !current.awayOnPhone
    }

    func canContinueOnPhone(_ record: ConversationRecord) -> Bool {
        telegram.canShare && telegram.canPost && !isSharing && record.sessionId != nil && !isAway(record)
    }

    func isAway(_ record: ConversationRecord) -> Bool {
        runtime(id: record.id, sessionId: record.sessionId)?.awayOnPhone ?? record.awayOnPhone
    }

    func isAway(_ entry: TelegramEntry) -> Bool {
        runtime(id: entry.record?.id ?? UUID(), sessionId: entry.topic.sessionId)?.awayOnPhone ?? entry.record?.awayOnPhone ?? false
    }

    var isAwayCurrent: Bool { current.awayOnPhone }

    func continueOnPhoneCurrent() {
        guard canContinueOnPhoneCurrent, let sessionId = state.sessionId else { return }
        continueOnPhone(id: currentId, sessionId: sessionId, cwd: current.cwd ?? profile.agent.cwd,
                        name: currentTitle ?? "Conversa", record: records.first { $0.id == currentId })
    }

    func continueOnPhone(_ record: ConversationRecord) {
        guard canContinueOnPhone(record), let sessionId = record.sessionId else { return }
        continueOnPhone(id: record.id, sessionId: sessionId, cwd: record.cwd ?? profile.agent.cwd, name: record.title, record: record)
    }

    func continueOnPhone(_ entry: TelegramEntry) {
        guard telegram.canPost, !isSharing, !isAway(entry) else { return }
        let record = entry.record ?? ConversationRecord(
            id: UUID(), sessionId: entry.topic.sessionId, title: entry.topic.name,
            updatedAt: entry.topic.lastUsed ?? Date(), cwd: entry.topic.cwd)
        continueOnPhone(id: record.id, sessionId: entry.topic.sessionId, cwd: entry.topic.cwd, name: record.title, record: record)
    }

    func returnToMacCurrent() { setAway(false, id: currentId, record: records.first { $0.id == currentId }) }

    func returnToMac(_ record: ConversationRecord) { setAway(false, id: record.id, record: record) }

    func returnToMac(_ entry: TelegramEntry) {
        let alive = runtime(id: entry.record?.id ?? UUID(), sessionId: entry.topic.sessionId)
        guard let id = alive?.id ?? entry.record?.id else { return }
        setAway(false, id: id, record: entry.record)
    }

    private func setAway(_ value: Bool, id: UUID, record: ConversationRecord?) {
        if let runtime = runtimes[id] { runtime.setAwayOnPhone(value) } else if var record {
            record.awayOnPhone = value
            saveAway(record)
        }
    }

    func recordAwayOnPhone(_ value: Bool, id: UUID) {
        guard var record = records.first(where: { $0.id == id }), record.awayOnPhone != value else { return }
        record.awayOnPhone = value
        saveAway(record)
    }

    private func saveAway(_ record: ConversationRecord) {
        do { try save(record) } catch {
            log.error("phone mode not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func continueOnPhone(id: UUID, sessionId: String, cwd: String, name: String, record: ConversationRecord?) {
        sharingSession = sessionId
        let screen = current
        let runtime = runtime(id: id, sessionId: sessionId)
        runtime?.telegramNotice = nil
        screen.telegramNotice = nil
        let prefix = profile.agent.statusPrefix
        Task { [weak self] in
            guard let self else { return }
            defer { self.sharingSession = nil }
            await self.telegram.refreshTopicsIfStale(maxAge: 0)
            var thread = TelegramTopics.topic(forSession: sessionId, in: self.telegram.loadedTopics)?.thread
            if thread == nil {
                switch await self.telegram.share(session: sessionId, cwd: expandTilde(cwd), name: String(name.prefix(Self.titleLimit))) {
                case .success(let shared):
                    thread = shared.thread
                    await self.refreshTelegram()
                case .failure(let failure):
                    (runtime ?? screen).telegramNotice = failure.sentence
                    return
                }
            }
            guard let thread else { return }
            let messages: [ConversationMessage]
            if let runtime {
                messages = runtime.state.messages
            } else {
                let root = expandTilde(cwd)
                messages = await Task.detached(priority: .utility) {
                    TranscriptReader.load(sessionId: sessionId, cwd: root, statusPrefix: prefix, telegramHTML: true)
                }.value ?? []
            }
            let running = runtime?.turnRunning ?? false
            let text = PhoneHandoff.message(
                lastReply: PhoneHandoff.lastReply(in: messages, turnRunning: running),
                turnRunning: running,
                approval: runtime?.state.approvals.first)
            if let failure = await self.telegram.post(TelegramPost(thread: thread, user: "", reply: text)) {
                (runtime ?? screen).telegramNotice = failure.sentence
                return
            }
            if let runtime {
                runtime.setAwayOnPhone(true)
            } else if var record {
                record.awayOnPhone = true
                self.saveAway(record)
            }
        }
    }

    private func permissionModeChanged() {
        loadProfile()
        for runtime in runtimes.values { runtime.permissionModeChanged() }
    }

    // MARK: Pill

    private func restTarget() -> PillState {
        guard isThinking, let shell else { return .rest }
        if case .thinking(let step) = state.phase { shell.pillText = step ?? "\(personaName) pensando…" }
        return .active
    }

    func syncPill(for runtime: ConversationRuntime, result: Bool = false) {
        guard runtime === current else { return }
        syncPill(result: result)
    }

    private func syncPill(result: Bool = false) {
        guard let shell else { return }
        switch state.phase {
        case .thinking(let step):
            restTask?.cancel()
            shell.statusColor = .busy
            shell.pillText = step ?? "\(personaName) pensando…"
            if shell.state == .rest { shell.show(.active) }
        case .failed:
            shell.statusColor = .error
            showTransient("erro — retomar")
        case .idle:
            shell.statusColor = .ok
            if result, let text = resultPillText() {
                showTransient(text)
            } else {
                restTask?.cancel()
                if shell.state == .active { shell.show(.rest) }
            }
        }
    }

    private func resultPillText() -> String? {
        if let status = state.status, !status.isEmpty { return status }
        guard let last = state.messages.last, last.role == .assistant else { return nil }
        return String(last.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.pillBodyLimit))
    }

    private func showTransient(_ text: String) {
        guard let shell else { return }
        restTask?.cancel()
        #if DEBUG
        log.notice("pill transient: \(text, privacy: .public)")
        #endif
        shell.pillText = text
        if shell.state == .rest { shell.show(.active) }
        restTask = Task { [weak self] in
            try? await Task.sleep(for: Self.transientDuration)
            guard !Task.isCancelled, let shell = self?.shell, shell.state == .active else { return }
            shell.show(.rest)
        }
    }

    // MARK: Debug

    #if DEBUG
    func runDemo(arguments args: [String]) {
        func value(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        guard let ask = value("-WispDemoAsk") else { return }
        demoAsk2 = value("-WispDemoAsk2")
        demoRetry = value("-WispDemoRetry")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.shell?.show(.panel)
            self?.send(ask)
        }
    }

    func continueDemo(after event: SessionEvent, from runtime: ConversationRuntime) {
        guard runtime === current else { return }
        switch event {
        case .claude(.result) where state.phase == .idle:
            guard let text = demoAsk2 else { return }
            demoAsk2 = nil
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.send(text)
            }
        case .exited:
            guard let text = demoRetry else { return }
            demoRetry = nil
            log.notice("demo: failed, retrying in 3s resume=\(self.state.sessionId ?? "nil", privacy: .private)")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.retry()
                self?.send(text)
            }
        default:
            break
        }
    }
    #endif
}
