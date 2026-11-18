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

    private(set) var state = ConversationState()
    private(set) var records: [ConversationRecord] = []
    private(set) var onboarding: Onboarding?
    private(set) var profileError: String?
    private(set) var profile: Profile = .default
    private(set) var currentId = UUID()
    private(set) var currentTitle: String?
    private(set) var isLoadingHistory = false
    private(set) var rateLimit: RateLimit?
    let telegram = TelegramModel()
    private(set) var linkedThread: Int?
    private(set) var pendingAttachments: [URL] = []
    private(set) var attachmentNotice: String?
    private(set) var held: [HeldMessage] = []
    private(set) var inFlight: UUID?
    /// Last-message previews read from transcript tails, by `previewKey`; an empty value means "nothing to show".
    private(set) var tailPreviews: [String: String] = [:]

    @ObservationIgnored weak var shell: ShellController? {
        didSet { shell?.restTarget = { [weak self] in self?.restTarget() ?? .rest } }
    }
    @ObservationIgnored private let store: ConversationStore
    @ObservationIgnored private let outbox: Outbox
    @ObservationIgnored private var tailsLoading: Set<String> = []
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var drainSleeping = false
    @ObservationIgnored private var outboxBroken = false
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "conversation")
    @ObservationIgnored private var session: AgentSession?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStop: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<AgentSession, Error>?
    @ObservationIgnored private var historyLoad: UUID?
    @ObservationIgnored private var sentAt: ContinuousClock.Instant?
    @ObservationIgnored private var sessionCwd: String?
    @ObservationIgnored private var follower: TranscriptFollower?
    @ObservationIgnored private var followToken = UUID()
    @ObservationIgnored private var unseenPrompts: [ConversationMessage] = []
    @ObservationIgnored private var seenPrompts = 0
    @ObservationIgnored private var awaitingReply = false
    @ObservationIgnored private var replyDeadline: Task<Void, Never>?
    /// The mode the live session was started with, to tell whether the CLI took `auto`.
    @ObservationIgnored private var sessionMode: String?
    /// The permission mode changed mid-turn: the session restarts once the turn ends.
    @ObservationIgnored private var restartAfterTurn = false
    #if DEBUG
    @ObservationIgnored private var demoAsk2: String?
    @ObservationIgnored private var demoRetry: String?
    #endif

    private static let titleLimit = 40
    private static let pillBodyLimit = 60
    private static let transientDuration: Duration = .seconds(4)
    private static let linkedReplyLimit: Duration = .seconds(61 * 60)
    private static let attachmentLimit = 10
    private static let attachmentOrigin = "Wisp"
    private static let sendingStep = "Enviando ao Telegram…"
    private static let creatingStep = "Criando tópico no Telegram…"
    private static let heldPill = "na fila"
    private static let drainFloor: TimeInterval = 0.5

    /// DEBUG `-WispProfile <path>` loads a fixture profile and keeps conversations and outbox in `<its folder>/data`.
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

    private static func claimingStep(_ host: String) -> String { "Trazendo a conversa do \(host)…" }

    var personaName: String { profile.persona.name }

    var isThinking: Bool {
        if case .thinking = state.phase { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    init(
        store: ConversationStore = ConversationStore(directory: ConversationViewModel.dataDirectory),
        outbox: Outbox = Outbox(directory: ConversationViewModel.dataDirectory)
    ) {
        self.store = store
        self.outbox = outbox
        records = store.all()
        held = outbox.all()
        for note in [store.lastRecoveryNote, outbox.lastRecoveryNote].compactMap({ $0 }) {
            state.messages.append(ConversationMessage(role: .system, text: note))
        }
        loadProfile()
        probeClaude()
        Task { [weak self] in await self?.refreshTelegram() }
        startDrain()
        PermissionModel.shared.onChange = { [weak self] in self?.permissionModeChanged() }
    }

    var telegramNotice: String? {
        guard linkedThread == nil else { return nil }
        switch telegram.link {
        case .up, .remote, .checking: return nil
        case .notConfigured: return "Telegram desconectado — conversa só no Wisp"
        case .down: return "Telegram fora do ar — as mensagens ficam na fila"
        }
    }

    /// Messages of the open conversation still waiting for the bot, oldest first.
    var heldHere: [HeldMessage] { held.filter { $0.conversationId == currentId } }

    func isHeld(_ message: ConversationMessage) -> Bool { held.contains { $0.id == message.id } }

    func heldMark(_ message: ConversationMessage) -> HeldMark? {
        held.first { $0.id == message.id }.map { OutboxPlan.mark($0, telegramConfigured: telegramConfigured, inFlight: inFlight) }
    }

    /// The Conversa list dot: red when something there will not go on its own, amber while it waits.
    func heldDot(_ conversationId: UUID) -> StatusColor? {
        let mine = held.filter { $0.conversationId == conversationId }
        guard !mine.isEmpty else { return nil }
        return !telegramConfigured || mine.contains(where: \.isFailed) ? .error : .busy
    }

    private var telegramConfigured: Bool { profile.blocks?.telegram?.isComplete == true }

    var sections: ConversationSections {
        TelegramTopics.sections(records: records, topics: telegram.loadedTopics, order: AppSettings.shared.settings.telegramOrder)
    }

    // MARK: Last-message preview

    private static func previewKey(sessionId: String, stamp: Date?) -> String {
        "\(sessionId)|\(stamp?.timeIntervalSince1970 ?? 0)"
    }

    /// The row's last-message line: the stored one when it is current, else what the transcript tail gave (see `fillPreviews`).
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

    /// Reads, off the main actor and only from the end of each transcript, the previews the list still lacks.
    func fillPreviews() {
        let sections = self.sections
        struct Job { let key: String; let sessionId: String; let cwd: String; let linked: Bool }
        var jobs: [Job] = []
        for record in sections.wisp where record.lastPreview == nil {
            guard let sessionId = record.sessionId else { continue }
            jobs.append(Job(key: Self.previewKey(sessionId: sessionId, stamp: record.updatedAt), sessionId: sessionId,
                            cwd: expandTilde(record.cwd ?? profile.agent.cwd), linked: record.telegramThread != nil))
        }
        for entry in sections.telegram {
            if let record = entry.record, record.updatedAt >= (entry.topic.lastUsed ?? .distantPast), record.lastPreview != nil { continue }
            jobs.append(Job(key: Self.previewKey(sessionId: entry.topic.sessionId, stamp: entry.topic.lastUsed),
                            sessionId: entry.topic.sessionId, cwd: expandTilde(entry.topic.cwd), linked: true))
        }
        let prefix = profile.agent.statusPrefix
        for job in jobs where tailPreviews[job.key] == nil && tailsLoading.insert(job.key).inserted {
            Task { [weak self] in
                let found = await Task.detached(priority: .utility) {
                    ConversationPreview.load(sessionId: job.sessionId, cwd: job.cwd, statusPrefix: prefix, telegramHTML: job.linked)
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
        if telegramConfigured { startDrain() } else { stopDrain() }
        refreshHeldPhase()
    }

    /// The setup window closed: a Telegram connected or disconnected there (or a new name) applies now, and the
    /// outbox drain starts or stops with it.
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

    /// Picker, drop and paste all land here: links resolved, only regular files kept, the rest refused in one sentence.
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

    /// The bot's attachments folder when the profile names one (Telegram only takes files from there), else Wisp's own.
    private var attachmentsRoot: URL {
        if let folder = profile.blocks?.telegram?.attachments, !folder.isEmpty {
            return URL(fileURLWithPath: expandTilde(folder), isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Wisp/anexos", isDirectory: true)
    }

    /// Text, attachments or both. Attachments are copied (an APFS clone) into today's attachments folder and the
    /// prompt becomes the same block a phone upload makes, so the agent reads them the same way.
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

    /// A Telegram message goes into the outbox before anything else, so order, a quit or a conversation switch
    /// never lose it; the drain is the only thing that sends it.
    private func submit(prompt text: String, caption: String, files: [String]) -> Bool {
        if isFailed {
            if linkedThread != nil { state.phase = .idle } else { discardSession() }
        }
        let fresh = linkedThread == nil && session == nil && startTask == nil && state.sessionId == nil
        let viaTelegram = linkedThread != nil || !heldHere.isEmpty || (fresh && telegramConfigured)
        let id = UUID()
        let time = Date()
        if viaTelegram {
            let recordThread = records.first { $0.id == currentId }?.telegramThread
            let message = HeldMessage(id: id, conversationId: currentId, thread: linkedThread ?? recordThread, text: caption,
                                      heldAt: time, files: files.isEmpty ? nil : files)
            do {
                try outbox.append(message)
            } catch {
                log.error("outbox append failed: \(error.localizedDescription, privacy: .public)")
                attachmentNotice = "Não consegui guardar a mensagem na fila: \(error.localizedDescription)"
                return false
            }
            held = outbox.all()
        }
        ConversationReducer.userSent(&state, text: text, id: id, time: time)
        sentAt = .now
        #if DEBUG
        log.notice("send: \(text, privacy: .public)")
        #endif
        syncPill()
        guard viaTelegram else {
            let gen = generation
            Task { await deliver(text, generation: gen) }
            return true
        }
        if let prompt = state.messages.last { unseenPrompts.append(prompt) }
        if linkedThread == nil { persist() }
        startDrain(fresh: true)
        return true
    }

    func retry() {
        if linkedThread != nil {
            state.phase = .idle
            syncPill()
            return
        }
        discardSession()
        state.phase = .idle
        state.status = nil
        syncPill()
    }

    func newConversation() {
        discardSession()
        unlink()
        sessionCwd = nil
        state = ConversationState()
        currentId = UUID()
        currentTitle = nil
        historyLoad = nil
        isLoadingHistory = false
        syncPill()
    }

    func delete(_ record: ConversationRecord) {
        do {
            try store.delete(id: record.id)
        } catch {
            log.error("conversation delete failed: \(error.localizedDescription, privacy: .public)")
            state.messages.append(ConversationMessage(
                role: .system,
                text: "não consegui apagar a conversa: \(error.localizedDescription)"
            ))
            return
        }
        records = store.all()
        for message in held where message.conversationId == record.id && message.id != inFlight {
            discard(message)
        }
        if record.id == currentId { newConversation() }
    }

    func open(_ record: ConversationRecord) {
        if let thread = record.telegramThread, telegramOwns(thread) {
            let topic = telegram.loadedTopics?.first { $0.thread == thread }
            openLinked(
                thread: thread,
                sessionId: topic?.sessionId ?? record.sessionId,
                cwd: topic?.cwd ?? record.cwd ?? profile.agent.cwd,
                title: record.title,
                id: record.id
            )
            return
        }
        discardSession()
        unlink()
        sessionCwd = record.cwd
        var next = ConversationState()
        next.sessionId = record.sessionId
        state = next
        currentId = record.id
        currentTitle = record.title
        restoreHeld()
        syncPill()
        loadHistory(of: record)
    }

    private func loadHistory(of record: ConversationRecord) {
        let token = UUID()
        historyLoad = token
        guard let sessionId = record.sessionId else {
            isLoadingHistory = false
            if heldHere.isEmpty { state.messages.insert(Self.historyMissing, at: 0) }
            return
        }
        isLoadingHistory = true
        let cwd = expandTilde(record.cwd ?? profile.agent.cwd)
        let prefix = profile.agent.statusPrefix
        let linked = record.telegramThread != nil
        Task { [weak self] in
            let history = await Task.detached {
                TranscriptReader.load(sessionId: sessionId, cwd: cwd, statusPrefix: prefix, telegramHTML: linked)
            }.value
            guard let self, self.historyLoad == token else { return }
            self.historyLoad = nil
            self.isLoadingHistory = false
            self.state.messages.insert(contentsOf: history ?? [Self.historyMissing], at: 0)
        }
    }

    private static var historyMissing: ConversationMessage {
        ConversationMessage(role: .system, text: "histórico não encontrado")
    }

    // MARK: Telegram

    func refreshTelegram() async {
        await telegram.refresh()
        fillPreviews()
        shell?.notices.topicsLoaded(telegram.loadedTopics, following: linkedThread, records: records, statusPrefix: profile.agent.statusPrefix)
        guard let thread = linkedThread,
              let topic = telegram.loadedTopics?.first(where: { $0.thread == thread }),
              topic.sessionId != state.sessionId else { return }
        state.sessionId = topic.sessionId
        sessionCwd = topic.cwd
        follow(sessionId: topic.sessionId, cwd: topic.cwd)
    }

    func open(_ entry: TelegramEntry) {
        openLinked(
            thread: entry.topic.thread,
            sessionId: entry.topic.sessionId,
            cwd: entry.topic.cwd,
            title: entry.record?.title ?? entry.topic.name,
            id: entry.record?.id ?? UUID()
        )
    }

    func close(_ entry: TelegramEntry) {
        let thread = entry.topic.thread
        Task { [weak self] in
            guard let self else { return }
            await self.telegram.close(thread: thread)
            guard self.linkedThread == thread, let topics = self.telegram.loadedTopics,
                  !topics.contains(where: { $0.thread == thread }) else { return }
            self.unlink()
        }
    }

    private func telegramOwns(_ thread: Int) -> Bool {
        guard let topics = telegram.loadedTopics else { return true }
        return topics.contains { $0.thread == thread }
    }

    private func openLinked(thread: Int, sessionId: String?, cwd: String, title: String, id: UUID) {
        discardSession()
        unlink()
        var next = ConversationState()
        next.sessionId = sessionId
        state = next
        currentId = id
        currentTitle = title
        linkedThread = thread
        sessionCwd = cwd
        restoreHeld()
        syncPill()
        if let sessionId {
            isLoadingHistory = true
            follow(sessionId: sessionId, cwd: cwd)
        }
    }

    private func failLinked(_ sentence: String) {
        unseenPrompts.removeAll { !isHeld($0) }
        awaitingReply = false
        replyDeadline?.cancel()
        state.pendingTurns = 0
        state.phase = .failed(sentence)
        syncPill()
    }

    private func armReplyDeadline(generation gen: Int) {
        replyDeadline?.cancel()
        replyDeadline = Task { [weak self] in
            try? await Task.sleep(for: Self.linkedReplyLimit)
            guard !Task.isCancelled, let self, gen == self.generation, self.awaitingReply else { return }
            self.failLinked("o Telegram não respondeu em 1 h")
        }
    }

    /// Links a topic the bot just created; a conversation no longer open gets its index line instead.
    private func adopt(_ created: TelegramCreated, conversationId: UUID, title: String) {
        if conversationId == currentId {
            linkedThread = created.thread
            sessionCwd = created.cwd
            state.sessionId = created.sessionId
            currentTitle = currentTitle ?? String(title.prefix(Self.titleLimit))
            persist()
            follow(sessionId: created.sessionId, cwd: created.cwd)
        } else {
            let record = ConversationRecord(
                id: conversationId,
                sessionId: created.sessionId,
                title: records.first { $0.id == conversationId }?.title ?? String(title.prefix(Self.titleLimit)),
                updatedAt: Date(),
                telegramThread: created.thread,
                cwd: created.cwd,
                lastPreview: records.first { $0.id == conversationId }?.lastPreview,
                lastFrom: records.first { $0.id == conversationId }?.lastFrom
            )
            do {
                try store.upsert(record)
                records = store.all()
            } catch {
                log.error("conversation upsert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        Task { [weak self] in await self?.refreshTelegram() }
    }

    // MARK: Outbox (D15)

    private var holdReason: String { telegram.downReason ?? DeliveryPolicy.defaultHoldReason }

    /// A reopened conversation shows what still waits for the bot.
    private func restoreHeld() {
        let waiting = heldHere
        guard !waiting.isEmpty else { return }
        let prompts = waiting.map { ConversationMessage(role: .user, text: heldPrompt($0), id: $0.id, time: $0.heldAt) }
        unseenPrompts.append(contentsOf: prompts)
        state.messages.append(contentsOf: prompts)
        state.pendingTurns = waiting.filter { !$0.isFailed }.count
        refreshHeldPhase()
    }

    private func heldPrompt(_ message: HeldMessage) -> String {
        guard let files = message.files, !files.isEmpty else { return message.text }
        let staged = files.map { path in
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            return StagedAttachment(path: path, name: (path as NSString).lastPathComponent, bytes: bytes)
        }
        return MessageAttachments.compose(origin: Self.attachmentOrigin, files: staged, caption: message.text, user: profile.persona.user)
    }

    /// The line under the open conversation says why it waits; with nothing left to explain it stops saying "na fila".
    private func refreshHeldPhase() {
        let waiting = heldHere
        guard !waiting.isEmpty else { return }
        let reason = OutboxPlan.phaseReason(conversation: currentId, outbox.all(), now: Date(),
                                            botDown: telegramConfigured ? telegram.downReason : nil)
        if let reason {
            guard state.phase != .held(reason) else { return }
            ConversationReducer.held(&state, reason: reason)
        } else if case .held = state.phase {
            state.phase = telegramConfigured && waiting.contains(where: { !$0.isFailed }) ? .thinking(step: nil) : .idle
        } else if !waiting.contains(where: { !$0.isFailed }), isThinking, inFlight == nil {
            state.phase = .idle
        } else {
            return
        }
        syncPill()
    }

    func retryHeld(_ message: ConversationMessage) {
        guard telegramConfigured, let held = held.first(where: { $0.id == message.id }), held.isFailed else { return }
        do {
            try outbox.replace(OutboxPlan.retried(held))
        } catch {
            attachmentNotice = "Não consegui atualizar a fila: \(error.localizedDescription)"
            return
        }
        self.held = outbox.all()
        state.pendingTurns += 1
        state.phase = .thinking(step: nil)
        syncPill()
        startDrain(fresh: true)
    }

    /// Refused while the message is on its way: it may already be at the bot.
    func discardHeld(_ message: ConversationMessage) {
        guard message.id != inFlight, let held = held.first(where: { $0.id == message.id }) else { return }
        guard discard(held) else { return }
        state.messages.removeAll { $0.id == message.id }
        unseenPrompts.removeAll { $0.id == message.id }
        if !held.isFailed { state.pendingTurns = max(0, state.pendingTurns - 1) }
        if heldHere.isEmpty, case .held = state.phase {
            state.pendingTurns = 0
            state.phase = .idle
            syncPill()
        } else {
            refreshHeldPhase()
        }
        startDrain()
    }

    @discardableResult
    private func discard(_ message: HeldMessage) -> Bool {
        do {
            try outbox.remove(id: message.id)
        } catch {
            attachmentNotice = "Não consegui tirar a mensagem da fila: \(error.localizedDescription)"
            return false
        }
        held = outbox.all()
        deleteStaged(message.files ?? [])
        return true
    }

    /// Only Wisp's own staged copies, never a file outside the attachments folder.
    private func deleteStaged(_ paths: [String]) {
        let root = attachmentsRoot.standardizedFileURL.path + "/"
        for path in paths where URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// A sleeping drain restarts at once; a running pass re-reads the outbox, so it never runs twice.
    private func startDrain(fresh: Bool = false) {
        guard telegramConfigured, !outboxBroken, OutboxPlan.hasWork(outbox.all()) else { return }
        if let drainTask {
            guard drainSleeping else { return }
            drainTask.cancel()
        }
        drainSleeping = false
        drainTask = Task { [weak self] in
            var fresh = fresh
            while let pause = await self?.drainPass(fresh: fresh) {
                fresh = false
                self?.drainSleeping = true
                do { try await Task.sleep(for: .seconds(pause)) } catch { return }
                self?.drainSleeping = false
            }
        }
    }

    /// A running pass checks the Telegram block itself before every message.
    private func stopDrain() {
        guard drainSleeping else { return }
        drainTask?.cancel()
        drainTask = nil
        drainSleeping = false
    }

    /// One look at the bot and everything it can take now; nil ends the drain. Asks every 10 s while held.
    private func drainPass(fresh: Bool) async -> TimeInterval? {
        guard telegramConfigured, !outboxBroken, OutboxPlan.hasWork(outbox.all()) else { return endDrain() }
        if fresh { await telegram.ensureFreshStatus() } else { await telegram.checkNow() }
        if telegram.canSend { await deliverHeld() }
        refreshHeldPhase()
        guard telegramConfigured, !outboxBroken, OutboxPlan.hasWork(outbox.all()) else { return endDrain() }
        return telegram.canSend ? max(Self.drainFloor, OutboxPlan.pause(outbox.all(), now: Date())) : OutboxPlan.poll
    }

    private func endDrain() -> TimeInterval? {
        drainTask = nil
        drainSleeping = false
        return nil
    }

    private func deliverHeld() async {
        while telegramConfigured, !outboxBroken, telegram.canSend, let next = OutboxPlan.next(outbox.all(), now: Date()) {
            inFlight = next.id
            let go = await deliverOne(next)
            inFlight = nil
            guard go else { return }
        }
    }

    /// Claim, create when the conversation has no topic yet, then send; false stops the pass.
    private func deliverOne(_ message: HeldMessage) async -> Bool {
        let here = { message.conversationId == self.currentId }
        if here() {
            state.phase = .thinking(step: nil)
            syncPill()
        }
        if let missing = OutboxPlan.missingFile(message, exists: { FileManager.default.fileExists(atPath: $0) }) {
            return fail(message, "o anexo \(missing) sumiu", retry: false)
        }
        if telegram.claimNeed != .none {
            if here(), let host = telegram.claimFrom {
                state.phase = .thinking(step: Self.claimingStep(host))
                syncPill()
            }
            if let failure = await telegram.claim(thread: message.thread) { return await settle(message, failure) }
        }
        var thread = OutboxPlan.thread(message, record: records.first { $0.id == message.conversationId }?.telegramThread,
                                       linked: here() ? linkedThread : nil)
        if thread == nil {
            if here() {
                state.phase = .thinking(step: Self.creatingStep)
                syncPill()
            }
            let files = message.files ?? []
            let name = MessageAttachments.firstMessageName(caption: message.text, names: files.map { ($0 as NSString).lastPathComponent })
            switch await telegram.create(name: TelegramTopics.topicName(from: name), cwd: expandTilde(profile.agent.cwd)) {
            case .success(let created):
                adopt(created, conversationId: message.conversationId, title: name)
                do {
                    try outbox.assignThread(created.thread, conversationId: message.conversationId)
                } catch {
                    log.error("outbox thread failed: \(error.localizedDescription, privacy: .public)")
                    _ = fail(message, "Não consegui guardar o tópico na fila: \(error.localizedDescription)", retry: false)
                    return false
                }
                held = outbox.all()
                thread = created.thread
            case .failure(let failure):
                return await settle(message, failure)
            }
        }
        guard let thread else { return false }
        if here() {
            awaitingReply = true
            state.phase = .thinking(step: Self.sendingStep)
            syncPill()
        }
        if let failure = await telegram.send(thread: thread, text: message.text, files: message.files ?? []) {
            return await settle(message, failure)
        }
        guard release(message) else { return false }
        if Notices.outboxSentIsNews(message, now: Date()) {
            noticeOutbox(message, preview: "Enviada: \(message.text)", tone: .normal)
        }
        if here(), !heldHere.contains(where: { !$0.isFailed }) {
            state.phase = .thinking(step: nil)
            syncPill()
            armReplyDeadline(generation: generation)
        }
        return true
    }

    /// The bot down is not an attempt: the message keeps its place and the pass stops. A failure with the bot up
    /// (or one that may already have arrived) counts.
    private func settle(_ message: HeldMessage, _ failure: TelegramFailure) async -> Bool {
        if failure.retry {
            await telegram.checkNow()
            if !telegram.canSend {
                refreshHeldPhase()
                return false
            }
        }
        return fail(message, failure.sentence, retry: failure.retry)
    }

    /// Keeps the message with its failure; other conversations keep draining, this one waits behind it.
    private func fail(_ message: HeldMessage, _ sentence: String, retry: Bool) -> Bool {
        let next: HeldMessage
        do {
            guard let failed = try outbox.fail(id: message.id, sentence: sentence, now: Date(), retry: retry) else { return true }
            next = failed
        } catch {
            stopOutbox(error)
            return false
        }
        held = outbox.all()
        log.error("held message failed (attempt \(next.attempts, privacy: .public)): \(sentence, privacy: .public)")
        if next.isFailed { noticeOutbox(next, preview: "Não enviada: \(sentence)", tone: .alert) }
        guard message.conversationId == currentId else { return true }
        if next.isFailed {
            awaitingReply = false
            state.pendingTurns = max(0, state.pendingTurns - 1)
            state.phase = .idle
            syncPill()
            refreshHeldPhase()
            if let shell {
                shell.statusColor = .error
                showTransient("mensagem não enviada")
            }
        } else {
            refreshHeldPhase()
        }
        return true
    }

    /// A message that left but cannot leave the file would be sent again on the next pass, so the outbox stops.
    private func release(_ message: HeldMessage) -> Bool {
        do {
            try outbox.remove(id: message.id)
            held = outbox.all()
            return true
        } catch {
            stopOutbox(error)
            return false
        }
    }

    private func stopOutbox(_ error: Error) {
        outboxBroken = true
        log.error("outbox write failed: \(error.localizedDescription, privacy: .public)")
        state.messages.append(ConversationMessage(role: .system, text: "Não consegui atualizar a fila do Telegram: \(error.localizedDescription)"))
    }

    private func follow(sessionId: String, cwd: String) {
        follower?.stop()
        let token = UUID()
        followToken = token
        seenPrompts = 0
        let next = TranscriptFollower(
            sessionId: sessionId,
            cwd: expandTilde(cwd),
            statusPrefix: profile.agent.statusPrefix,
            telegramHTML: true
        ) { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot, token: token) }
            }
        }
        follower = next
        next.start()
    }

    private func apply(_ snapshot: TranscriptParser.Snapshot, token: UUID) {
        guard token == followToken else { return }
        isLoadingHistory = false
        let landed = snapshot.messages.filter { $0.role == .user }.suffix(max(0, snapshot.prompts - seenPrompts))
        seenPrompts = snapshot.prompts
        for prompt in landed {
            if let index = unseenPrompts.firstIndex(where: { $0.text == prompt.text }) { unseenPrompts.remove(at: index) }
        }
        state.messages = snapshot.messages + unseenPrompts
        let stillGoing = unseenPrompts.contains { prompt in !(held.first { $0.id == prompt.id }?.isFailed ?? false) }
        guard awaitingReply, !stillGoing, !snapshot.turnOpen else { return }
        awaitingReply = false
        replyDeadline?.cancel()
        state.pendingTurns = 0
        state.status = snapshot.status
        if !isFailed { state.phase = .idle }
        persist()
        logLatency()
        syncPill(result: true)
        noticeReply()
    }

    private func unlink() {
        follower?.stop()
        follower = nil
        followToken = UUID()
        linkedThread = nil
        unseenPrompts = []
        seenPrompts = 0
        awaitingReply = false
        replyDeadline?.cancel()
        replyDeadline = nil
    }

    // MARK: Session

    private func discardSession() {
        generation += 1
        sessionMode = nil
        restartAfterTurn = false
        eventTask?.cancel()
        eventTask = nil
        startTask = nil
        ConversationReducer.sessionDiscarded(&state)
        let old = session
        session = nil
        if let old { chainStop(old) }
    }

    private func chainStop(_ old: AgentSession) {
        let previous = pendingStop
        pendingStop = Task {
            await previous?.value
            await old.stop()
        }
    }

    private func ensureSession() async throws -> AgentSession {
        if let session { return session }
        if let startTask { return try await startTask.value }
        let gen = generation
        let task = Task { try await self.startSession(generation: gen) }
        startTask = task
        return try await task.value
    }

    private func startSession(generation gen: Int) async throws -> AgentSession {
        do {
            await pendingStop?.value
            guard gen == generation else { throw CancellationError() }
            let configured = profile.agent.claudePath
            let executable = try await Task.detached { try ClaudeLocator.resolve(configured: configured) }.value
            guard gen == generation else { throw CancellationError() }
            let resume = state.sessionId
            PermissionModel.shared.refresh()
            let mode = PermissionModel.shared.cliMode
            let next = AgentSession(
                executable: executable,
                cwd: URL(fileURLWithPath: expandTilde(sessionCwd ?? profile.agent.cwd)),
                model: profile.agent.model,
                resume: resume,
                permissionMode: mode
            )
            try await next.start()
            guard gen == generation else {
                chainStop(next)
                throw CancellationError()
            }
            session = next
            sessionMode = mode
            startTask = nil
            log.notice("session started resume=\(resume ?? "nil", privacy: .private) mode=\(mode ?? "claude", privacy: .public)")
            eventTask = Task { [weak self] in
                for await event in next.events { self?.handle(event, generation: gen) }
            }
            return next
        } catch {
            if gen == generation { startTask = nil }
            throw error
        }
    }

    private func deliver(_ text: String, generation gen: Int) async {
        guard linkedThread == nil else { return }
        do {
            let active = try await ensureSession()
            guard gen == generation else { return }
            try await active.send(text)
        } catch is CancellationError {
            return
        } catch AgentError.claudeNotFound {
            guard gen == generation else { return }
            onboarding = .claudeMissing
            ConversationReducer.sessionDiscarded(&state)
            state.phase = .idle
            syncPill()
        } catch {
            guard gen == generation else { return }
            state.pendingTurns = 0
            state.phase = .failed("não consegui falar com o claude: \(error.localizedDescription)")
            syncPill()
        }
    }

    // MARK: Events

    private func handle(_ event: SessionEvent, generation gen: Int) {
        guard gen == generation else { return }
        #if DEBUG
        log.notice("event: \(String(String(describing: event).prefix(300)), privacy: .public)")
        #endif
        let before = state.phase
        ConversationReducer.reduce(&state, event, statusPrefix: profile.agent.statusPrefix)
        if case .claude(.usage(let limit)) = event { rateLimit = limit }

        var isResult = false
        if case .claude(.result(_, let text, let isError, _)) = event {
            isResult = true
            if isError, state.subscription == false, ConversationReducer.isAuthError(text) {
                onboarding = .authRequired
            }
            if !isError { persist() }
            logLatency()
        }
        if isResult || state.phase != before { syncPill(result: isResult) }
        if case .claude(.result(_, _, false, _)) = event { noticeReply() }
        if case .claude(.permissionRequest(let request)) = event { noticeApproval(request) }
        if case .claude(.permissionMode(let mode)) = event { reportedMode(mode) }
        #if DEBUG
        continueDemo(after: event)
        #endif
        if isResult, restartAfterTurn, state.pendingTurns == 0 {
            restartAfterTurn = false
            discardSession()
        }
    }

    // MARK: Permissions

    /// The card's buttons. The reducer moves on at once; the CLI holds the tool call until the line lands.
    func answer(_ request: PermissionRequest, _ decision: PermissionDecision) {
        guard state.approvals.contains(where: { $0.id == request.id }) else { return }
        ConversationReducer.approvalAnswered(&state, id: request.id, decision: decision)
        syncPill()
        guard let active = session else { return }
        let gen = generation
        Task { [weak self] in
            do {
                try await active.respond(to: request, decision)
            } catch {
                guard let self, gen == self.generation else { return }
                self.log.error("permission answer failed: \(error.localizedDescription, privacy: .public)")
                self.state.messages.append(ConversationMessage(role: .system, text: "não consegui responder ao claude: a sessão acabou"))
            }
        }
    }

    /// A new mode applies to the next start: an idle session stops now (the next message resumes it with the
    /// new mode), a turn in flight finishes first.
    private func permissionModeChanged() {
        loadProfile()
        guard session != nil || startTask != nil else { return }
        if state.pendingTurns == 0 {
            discardSession()
        } else {
            restartAfterTurn = true
        }
    }

    private func reportedMode(_ mode: String) {
        PermissionModel.shared.sessionReported(mode: mode, requested: sessionMode)
        guard sessionMode == PermissionChoice.auto.rawValue, mode != sessionMode else { return }
        state.messages.append(ConversationMessage(
            role: .system,
            text: "o modo Automático não está disponível nesta conta; esta conversa roda no modo \(mode)"
        ))
    }

    private func logLatency() {
        guard let sentAt else { return }
        let elapsed = sentAt.duration(to: .now)
        #if DEBUG
        log.notice("latency: \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)), privacy: .public) phase=\(String(describing: self.state.phase), privacy: .public) status=\(self.state.status ?? "nil", privacy: .public)")
        #endif
        self.sentAt = nil
    }

    private func persist() {
        guard let first = state.messages.first(where: { $0.role == .user }) else { return }
        let last = ConversationPreview.last(of: state.messages)
        let record = ConversationRecord(
            id: currentId,
            sessionId: state.sessionId,
            title: currentTitle ?? String((MessageAttachments.parse(first.text)?.summary ?? first.text).prefix(Self.titleLimit)),
            updatedAt: Date(),
            telegramThread: linkedThread,
            cwd: sessionCwd,
            lastPreview: last?.text,
            lastFrom: last?.from
        )
        currentTitle = record.title
        do {
            try store.upsert(record)
            records = store.all()
        } catch {
            log.error("conversation upsert failed: \(error.localizedDescription, privacy: .public)")
            state.messages.append(ConversationMessage(
                role: .system,
                text: "não consegui salvar a conversa: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: Notices

    /// A reply landed in the open conversation; the notice center drops it when that conversation is on screen.
    private func noticeReply() {
        guard let shell, let last = state.messages.last, last.role == .assistant else { return }
        shell.notices.post(Notice(
            kind: .reply,
            title: currentTitle ?? personaName,
            preview: Notices.preview(last.text),
            time: Date(),
            target: linkedThread.map(NoticeTarget.topic) ?? .conversation(currentId)
        ))
    }

    /// The panel closed (or on another screen) while a tool call waits for the user.
    private func noticeApproval(_ request: PermissionRequest) {
        shell?.notices.post(Notice(
            sourceId: "approval:\(currentId.uuidString)",
            kind: .approval,
            title: "O Claude precisa da tua aprovação",
            preview: Notices.preview("Quer \(request.summary)"),
            time: Date(),
            target: .conversation(currentId),
            tone: .warning
        ))
    }

    /// The conversation when Wisp knows it, else its topic; with neither the click lands on the Conversa list.
    private func noticeTarget(for message: HeldMessage) -> NoticeTarget {
        let known = message.conversationId == currentId || records.contains { $0.id == message.conversationId }
        if !known, let thread = message.thread { return .topic(thread) }
        return .conversation(message.conversationId)
    }

    private func noticeOutbox(_ message: HeldMessage, preview: String, tone: Notice.Tone) {
        let title = records.first { $0.id == message.conversationId }?.title
            ?? (message.conversationId == currentId ? currentTitle : nil)
        shell?.notices.post(Notice(
            sourceId: "outbox:\(message.id.uuidString)",
            kind: .outbox,
            title: title ?? "Fila do Telegram",
            preview: Notices.preview(preview),
            time: Date(),
            target: noticeTarget(for: message),
            tone: tone
        ))
    }

    // MARK: Pill

    private func restTarget() -> PillState {
        guard isThinking, let shell else { return .rest }
        if case .thinking(let step) = state.phase { shell.pillText = step ?? "\(personaName) pensando…" }
        return .active
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
        case .held:
            shell.statusColor = .busy
            showTransient(Self.heldPill)
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
        for (key, act) in [("-WispDemoDiscardAfter", discardHeld), ("-WispDemoRetryAfter", retryHeld)] {
            guard let seconds = value(key).flatMap(Double.init) else { continue }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, let first = self.heldHere.first,
                      let message = self.state.messages.first(where: { $0.id == first.id }) else { return }
                self.log.notice("demo: \(key, privacy: .public) \(first.id, privacy: .public)")
                act(message)
            }
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

    private func continueDemo(after event: SessionEvent) {
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
