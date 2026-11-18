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

    @ObservationIgnored weak var shell: ShellController? {
        didSet { shell?.restTarget = { [weak self] in self?.restTarget() ?? .rest } }
    }
    @ObservationIgnored private let store: ConversationStore
    @ObservationIgnored private let log = Logger(subsystem: "com.owner.wisp", category: "conversation")
    @ObservationIgnored private var session: AgentSession?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStop: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<AgentSession, Error>?
    @ObservationIgnored private var historyLoad: UUID?
    @ObservationIgnored private var sentAt: ContinuousClock.Instant?
    @ObservationIgnored private var engine: Task<Engine, Never>?
    @ObservationIgnored private var sessionCwd: String?
    @ObservationIgnored private var follower: TranscriptFollower?
    @ObservationIgnored private var followToken = UUID()
    @ObservationIgnored private var unseenPrompts: [ConversationMessage] = []
    @ObservationIgnored private var seenPrompts = 0
    @ObservationIgnored private var awaitingReply = false
    @ObservationIgnored private var replyDeadline: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private var demoAsk2: String?
    @ObservationIgnored private var demoRetry: String?
    #endif

    private enum Engine {
        case local
        case topic(Int)
        case failed
    }

    private static let titleLimit = 40
    private static let pillBodyLimit = 60
    private static let transientDuration: Duration = .seconds(4)
    private static let linkedReplyLimit: Duration = .seconds(61 * 60)
    private static let attachmentLimit = 10
    private static let attachmentOrigin = "Wisp"
    private static let sendingStep = "Enviando ao Telegram…"
    private static let creatingStep = "Criando tópico no Telegram…"

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

    init(store: ConversationStore = ConversationStore()) {
        self.store = store
        records = store.all()
        if let note = store.lastRecoveryNote {
            state.messages.append(ConversationMessage(role: .system, text: note))
        }
        loadProfile()
        probeClaude()
        Task { [weak self] in await self?.refreshTelegram() }
    }

    var telegramNotice: String? {
        guard linkedThread == nil else { return nil }
        switch telegram.link {
        case .up, .remote, .checking: return nil
        case .notConfigured, .down: return "Telegram desconectado — conversa só no Wisp"
        }
    }

    var sections: ConversationSections {
        TelegramTopics.sections(records: records, topics: telegram.loadedTopics, order: AppSettings.shared.settings.telegramOrder)
    }

    // MARK: Onboarding

    private func loadProfile() {
        do {
            profile = try ProfileLoader.load(from: ProfileLoader.defaultURL)
            profileError = nil
            telegram.configure(profile.blocks?.telegram)
        } catch {
            profileError = error.localizedDescription
        }
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
        guard !pendingAttachments.isEmpty else {
            submit(prompt: text, caption: text, files: [])
            return true
        }
        do {
            let staged = try AttachmentStaging.stage(pendingAttachments, into: attachmentsRoot)
            pendingAttachments = []
            attachmentNotice = nil
            submit(prompt: MessageAttachments.compose(origin: Self.attachmentOrigin, files: staged, caption: text, user: profile.persona.user),
                   caption: text, files: staged.map(\.path),
                   name: MessageAttachments.firstMessageName(caption: text, names: staged.map(\.name)))
            return true
        } catch {
            attachmentNotice = "Não consegui preparar o anexo: \(error.localizedDescription)"
            return false
        }
    }

    private func submit(prompt text: String, caption: String, files: [String], name: String? = nil) {
        let name = name ?? caption
        if isFailed {
            if linkedThread != nil { state.phase = .idle } else { discardSession() }
        }
        let fresh = linkedThread == nil && engine == nil && session == nil && startTask == nil && state.sessionId == nil
        ConversationReducer.userSent(&state, text: text)
        sentAt = .now
        #if DEBUG
        log.notice("send: \(text, privacy: .public)")
        #endif
        syncPill()
        let gen = generation
        if fresh, profile.blocks?.telegram?.isComplete == true {
            engine = Task { await self.chooseEngine(firstMessage: name, generation: gen) }
        }
        guard let engine else {
            Task { await deliver(text, generation: gen) }
            return
        }
        if let prompt = state.messages.last, prompt.role == .user { unseenPrompts.append(prompt) }
        Task {
            switch await engine.value {
            case .topic(let thread):
                await self.deliverLinked(caption, files: files, thread: thread, generation: gen)
            case .local:
                self.unseenPrompts.removeAll { $0.text == text }
                await self.deliver(text, generation: gen)
            case .failed:
                break
            }
        }
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
        syncPill()
        loadHistory(of: record)
    }

    private func loadHistory(of record: ConversationRecord) {
        let token = UUID()
        historyLoad = token
        guard let sessionId = record.sessionId else {
            isLoadingHistory = false
            state.messages.insert(Self.historyMissing, at: 0)
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
        engine = Task { .topic(thread) }
        syncPill()
        if let sessionId {
            isLoadingHistory = true
            follow(sessionId: sessionId, cwd: cwd)
        }
    }

    private func chooseEngine(firstMessage text: String, generation gen: Int) async -> Engine {
        await telegram.ensureFreshStatus()
        guard gen == generation, telegram.canSend else { return .local }
        if let failure = await claimReader(thread: nil, generation: gen) {
            guard gen == generation else { return .failed }
            failLinked(failure.sentence)
            engine = nil
            return .failed
        }
        guard gen == generation else { return .failed }
        state.phase = .thinking(step: Self.creatingStep)
        syncPill()
        let cwd = expandTilde(profile.agent.cwd)
        switch await telegram.create(name: TelegramTopics.topicName(from: text), cwd: cwd) {
        case .success(let created):
            guard gen == generation else { return .failed }
            linkedThread = created.thread
            sessionCwd = created.cwd
            state.sessionId = created.sessionId
            currentTitle = currentTitle ?? String(text.prefix(Self.titleLimit))
            persist()
            follow(sessionId: created.sessionId, cwd: created.cwd)
            Task { [weak self] in await self?.refreshTelegram() }
            return .topic(created.thread)
        case .failure(let failure):
            guard gen == generation else { return .failed }
            failLinked(failure.sentence)
            engine = nil
            return .failed
        }
    }

    private func deliverLinked(_ text: String, files: [String], thread: Int, generation gen: Int) async {
        guard gen == generation else { return }
        awaitingReply = true
        await telegram.ensureFreshStatus()
        guard gen == generation else { return }
        if let failure = await claimReader(thread: thread, generation: gen) {
            guard gen == generation else { return }
            failLinked(failure.sentence)
            return
        }
        guard gen == generation else { return }
        if case .thinking(let step) = state.phase, step == nil || step == Self.creatingStep {
            state.phase = .thinking(step: Self.sendingStep)
            syncPill()
        }
        let failure = await telegram.send(thread: thread, text: text, files: files)
        guard gen == generation else { return }
        if let failure {
            failLinked(failure.sentence)
            return
        }
        if state.phase == .thinking(step: Self.sendingStep) {
            state.phase = .thinking(step: nil)
            syncPill()
        }
        armReplyDeadline(generation: gen)
    }

    private func claimReader(thread: Int?, generation gen: Int) async -> TelegramFailure? {
        guard telegram.claimNeed != .none else { return nil }
        let handOff = telegram.claimFrom
        if let handOff {
            state.phase = .thinking(step: Self.claimingStep(handOff))
            syncPill()
        }
        let failure = await telegram.claim(thread: thread)
        if handOff != nil, gen == generation, failure == nil {
            state.phase = .thinking(step: nil)
            syncPill()
        }
        return failure
    }

    private func failLinked(_ sentence: String) {
        unseenPrompts = []
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
        guard awaitingReply, unseenPrompts.isEmpty, !snapshot.turnOpen else { return }
        awaitingReply = false
        replyDeadline?.cancel()
        state.pendingTurns = 0
        state.status = snapshot.status
        if !isFailed { state.phase = .idle }
        persist()
        logLatency()
        syncPill(result: true)
    }

    private func unlink() {
        follower?.stop()
        follower = nil
        followToken = UUID()
        engine = nil
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
            let next = AgentSession(
                executable: executable,
                cwd: URL(fileURLWithPath: expandTilde(sessionCwd ?? profile.agent.cwd)),
                model: profile.agent.model,
                resume: resume
            )
            try await next.start()
            guard gen == generation else {
                chainStop(next)
                throw CancellationError()
            }
            session = next
            startTask = nil
            log.notice("session started resume=\(resume ?? "nil", privacy: .private)")
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
        #if DEBUG
        continueDemo(after: event)
        #endif
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
        let record = ConversationRecord(
            id: currentId,
            sessionId: state.sessionId,
            title: currentTitle ?? String((MessageAttachments.parse(first.text)?.summary ?? first.text).prefix(Self.titleLimit)),
            updatedAt: Date(),
            telegramThread: linkedThread,
            cwd: sessionCwd
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
