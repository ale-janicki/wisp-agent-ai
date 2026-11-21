import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class ConversationRuntime {
    let id: UUID
    private(set) var state = ConversationState()
    private(set) var title: String?
    private(set) var isLoadingHistory = false
    private(set) var waitingForTelegram = false
    var telegramNotice: String?
    var unseenReply = false
    private(set) var lastUsed = Date()
    private(set) var cwd: String?
    private(set) var awayOnPhone: Bool

    @ObservationIgnored weak var host: ConversationViewModel!
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "conversation")
    @ObservationIgnored private var turnLease: SessionLock.Lease?
    @ObservationIgnored private var mirrorUsers: [(user: String, files: [String])] = []
    @ObservationIgnored private var deliveryTail: Task<Void, Never>?
    @ObservationIgnored private var deliveries: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastTurnEnded: Date?
    @ObservationIgnored private var turnsInFlight = 0
    @ObservationIgnored private var followedSession: String?
    @ObservationIgnored private var session: AgentSession?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingStop: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<AgentSession, Error>?
    @ObservationIgnored private var historyLoad: UUID?
    @ObservationIgnored private var sentAt: ContinuousClock.Instant?
    @ObservationIgnored private var follower: TranscriptFollower?
    @ObservationIgnored private var followToken = UUID()
    @ObservationIgnored private var sessionMode: String?
    @ObservationIgnored private var answering: Set<String> = []
    @ObservationIgnored private var restartAfterTurn = false
    @ObservationIgnored private var launchedContext: AgentInstructions.Context?

    @ObservationIgnored private var titleGenerated: Bool
    @ObservationIgnored private var titleRequested: Bool

    init(id: UUID = UUID(), title: String? = nil, cwd: String? = nil, sessionId: String? = nil, titleGenerated: Bool = false, awayOnPhone: Bool = false) {
        self.id = id
        self.awayOnPhone = awayOnPhone
        self.title = title
        self.titleGenerated = titleGenerated
        self.titleRequested = title != nil
        self.cwd = cwd
        state.sessionId = sessionId
    }

    // MARK: Reading

    var isThinking: Bool {
        if case .thinking = state.phase { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    var turnRunning: Bool { isThinking || state.pendingTurns > 0 }

    var hasProcess: Bool { session != nil || startTask != nil }

    var isBusy: Bool {
        turnRunning || turnsInFlight > 0 || !deliveries.isEmpty || startTask != nil || !state.approvals.isEmpty
    }

    var linkedThread: Int? {
        TelegramTopics.topic(forSession: state.sessionId, in: host.telegram.loadedTopics)?.thread
    }

    func snapshot(isCurrent: Bool) -> RuntimeSnapshot {
        RuntimeSnapshot(id: id, isCurrent: isCurrent, hasProcess: hasProcess, isBusy: isBusy,
                        hasUnseenReply: unseenReply, lastUsed: lastUsed)
    }

    private func agentContext() -> AgentInstructions.Context {
        AgentInstructions.context(thread: linkedThread, wispBinary: resolvedWispBinary(), awayOnPhone: awayOnPhone)
    }

    private func resolvedWispBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let layout = RuntimeLayout(bundle: Bundle.main.bundleURL, home: home)
        return EngineGuards.wispBinary(telegramBinary: host.telegram.wispBinary, layout: layout)
    }

    private struct GuardsUnavailable: Error { let reason: String }

    private func guardSettingsPath() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let bin = resolvedWispBinary() else {
            log.error("no wisp CLI for the engine guards; the turn is refused")
            throw GuardsUnavailable(reason: "não achei o CLI do Wisp")
        }
        do {
            return try EngineGuards.install(wispBinary: bin, at: EngineGuards.settingsURL(home: home)).path
        } catch {
            log.error("could not write the engine guard settings: \(String(describing: error), privacy: .public)")
            throw GuardsUnavailable(reason: error.localizedDescription)
        }
    }

    private func isInTelegram(_ sessionId: String?) -> Bool {
        TelegramTopics.topic(forSession: sessionId, in: host.telegram.loadedTopics) != nil
    }

    func touch() { lastUsed = Date() }

    func setAwayOnPhone(_ value: Bool) {
        guard awayOnPhone != value else { return }
        awayOnPhone = value
        host.recordAwayOnPhone(value, id: id)
    }

    func appendSystem(_ text: String) {
        state.messages.append(ConversationMessage(role: .system, text: text))
    }

    // MARK: Sending

    func submit(prompt text: String, caption: String) {
        setAwayOnPhone(false)
        if isFailed { discardSession() }
        let id = UUID()
        ConversationReducer.userSent(&state, text: text, id: id, time: Date())
        telegramNotice = nil
        sentAt = .now
        lastUsed = Date()
        #if DEBUG
        log.notice("send: \(text, privacy: .public)")
        #endif
        host.syncPill(for: self)
        let user = caption.isEmpty ? text : caption
        let previous = deliveryTail
        let deliveryId = UUID()
        let task = Task { [weak self] in
            await previous?.value
            await self?.deliver(text, user: user)
            self?.deliveries[deliveryId] = nil
        }
        deliveries[deliveryId] = task
        deliveryTail = task
    }

    func retry() {
        discardSession()
        state.phase = .idle
        state.status = nil
        host.syncPill(for: self)
    }

    func shutdown() {
        discardSession()
        unfollow()
        historyLoad = nil
    }

    func stopIdleProcess() {
        guard hasProcess, !isBusy else { return }
        discardSession()
    }

    // MARK: History and following

    func loadHistory(of record: ConversationRecord) {
        let token = UUID()
        historyLoad = token
        guard let sessionId = record.sessionId else {
            isLoadingHistory = false
            state.messages.insert(Self.historyMissing, at: 0)
            return
        }
        isLoadingHistory = true
        let profile = host.profile
        let cwd = expandTilde(record.cwd ?? profile.agent.cwd)
        let prefix = profile.agent.statusPrefix
        Task { [weak self] in
            let history = await Task.detached {
                TranscriptReader.load(sessionId: sessionId, cwd: cwd, statusPrefix: prefix, telegramHTML: true)
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

    func startLinked(sessionId: String, cwd: String) {
        isLoadingHistory = true
        follow(sessionId: sessionId, cwd: cwd)
    }

    func syncFollowing() {
        if let topic = TelegramTopics.topic(forSession: state.sessionId, in: host.telegram.loadedTopics) {
            guard followedSession != topic.sessionId else { return }
            follow(sessionId: topic.sessionId, cwd: cwd ?? topic.cwd)
        } else if followedSession != nil {
            unfollow()
        }
    }

    private func follow(sessionId: String, cwd: String) {
        follower?.stop()
        let token = UUID()
        followToken = token
        followedSession = sessionId
        let next = TranscriptFollower(
            sessionId: sessionId,
            cwd: expandTilde(cwd),
            statusPrefix: host.profile.agent.statusPrefix,
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
        guard !turnRunning, !isFailed else { return }
        state.messages = snapshot.messages
        state.status = snapshot.status
    }

    private func unfollow() {
        follower?.stop()
        follower = nil
        followToken = UUID()
        followedSession = nil
    }

    // MARK: Session

    private func discardSession(keepingDeliveries: Bool = false) {
        generation += 1
        if !keepingDeliveries {
            for task in deliveries.values { task.cancel() }
            deliveries = [:]
            deliveryTail = nil
        }
        sessionMode = nil
        restartAfterTurn = false
        turnsInFlight = 0
        releaseTurn()
        eventTask?.cancel()
        eventTask = nil
        startTask = nil
        ConversationReducer.sessionDiscarded(&state)
        let old = session
        session = nil
        if let old { chainStop(old) }
    }

    private func restartProcess() {
        generation += 1
        sessionMode = nil
        restartAfterTurn = false
        turnsInFlight = 0
        waitingForTelegram = false
        eventTask?.cancel()
        eventTask = nil
        startTask = nil
        ConversationReducer.processRestarted(&state)
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
            let profile = host.profile
            let configured = profile.agent.claudePath
            let executable = try await Task.detached { try ClaudeLocator.resolve(configured: configured) }.value
            guard gen == generation else { throw CancellationError() }
            let resume = state.sessionId
            PermissionModel.shared.refresh()
            let mode = PermissionModel.shared.cliMode
            let context = agentContext()
            launchedContext = context
            let settings = try guardSettingsPath()
            let next = AgentSession(
                executable: executable,
                cwd: URL(fileURLWithPath: expandTilde(cwd ?? profile.agent.cwd)),
                model: profile.agent.model,
                resume: resume,
                permissionMode: mode,
                appendSystemPrompt: context.prompt,
                settingsPath: settings,
                disallowedTools: context.disallowedTools,
                environmentOverrides: context.environment
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

    private func releaseTurn() {
        lastTurnEnded = Date()
        turnLease?.release()
        turnLease = nil
        mirrorUsers = []
        waitingForTelegram = false
    }

    private func acquireTurn() async throws -> Bool {
        guard turnLease == nil, let sessionId = state.sessionId else { return !Task.isCancelled }
        await host.telegram.refreshTopicsIfStale()
        let contended = LockedFlag()
        let gen = generation
        let lease = try await host.sessionLock.acquire(sessionId: sessionId) { [weak self] in
            contended.set()
            Task { @MainActor in self?.waitingStarted(generation: gen) }
        }
        guard !Task.isCancelled else {
            lease.release()
            return false
        }
        waitingForTelegram = false
        if TurnRestartPolicy.shouldRestart(
            hasProcess: session != nil || startTask != nil,
            turnsInFlight: turnsInFlight,
            inTelegram: isInTelegram(sessionId),
            contended: contended.value,
            lastTurnEnded: lastTurnEnded,
            sessionModified: sessionModified(sessionId),
            contextChanged: launchedContext != agentContext()
        ) {
            restartProcess()
            state.phase = .thinking(step: nil)
        }
        turnLease = lease
        return true
    }

    private func sessionModified(_ sessionId: String) -> Date? {
        guard let url = TranscriptReader.locate(sessionId: sessionId, cwd: expandTilde(cwd ?? host.profile.agent.cwd))
        else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func waitingStarted(generation gen: Int) {
        guard gen == generation, turnLease == nil else { return }
        waitingForTelegram = true
        state.phase = .thinking(step: ConversationViewModel.waitingStep)
        host.syncPill(for: self)
    }

    private static func attachedPaths(_ text: String) -> [String] {
        MessageAttachments.parse(text)?.items.compactMap {
            if case .file(let path, _, _) = $0 { path } else { nil }
        } ?? []
    }

    private func deliver(_ text: String, user: String) async {
        guard !Task.isCancelled else { return }
        var gen = generation
        do {
            guard try await acquireTurn() else { return }
            gen = generation
            mirrorUsers.append((user, Self.attachedPaths(text)))
            let active = try await ensureSession()
            guard gen == generation else { return }
            try await active.send(text)
            if gen == generation { turnsInFlight += 1 }
        } catch is CancellationError {
            return
        } catch AgentError.claudeNotFound {
            guard gen == generation else { return }
            releaseTurn()
            host.setOnboarding(.claudeMissing)
            ConversationReducer.sessionDiscarded(&state)
            state.phase = .idle
            host.syncPill(for: self)
        } catch let unavailable as GuardsUnavailable {
            guard gen == generation else { return }
            releaseTurn()
            state.pendingTurns = 0
            state.phase = .failed("não consegui ativar as travas do Wisp: \(unavailable.reason)")
            host.syncPill(for: self)
        } catch {
            guard gen == generation else { return }
            releaseTurn()
            state.pendingTurns = 0
            state.phase = .failed("não consegui falar com o claude: \(error.localizedDescription)")
            host.syncPill(for: self)
        }
    }

    // MARK: Events

    private func handle(_ event: SessionEvent, generation gen: Int) {
        guard gen == generation else { return }
        #if DEBUG
        log.notice("event: \(String(String(describing: event).prefix(300)), privacy: .public)")
        #endif
        let before = state.phase
        ConversationReducer.reduce(&state, event, statusPrefix: host.profile.agent.statusPrefix)
        if case .claude(.usage(let limit)) = event { host.setRateLimit(limit) }

        var isResult = false
        var settled = false
        if case .claude(.result(_, let text, let isError, _)) = event {
            isResult = true
            settled = true
            lastUsed = Date()
            if isError, state.subscription == false, ConversationReducer.isAuthError(text) {
                host.setOnboarding(.authRequired)
            }
            if !isError {
                persist()
                generateTitle()
            }
            logLatency()
            turnsInFlight = max(0, turnsInFlight - 1)
            let sent = mirrorUsers.isEmpty ? nil : mirrorUsers.removeFirst()
            if !isError, let sent { mirror(user: sent.user, files: sent.files) }
            if state.pendingTurns == 0 { releaseTurn() }
            if !isError, !host.isCurrent(self) { unseenReply = true }
        }
        if case .exited = event {
            settled = true
            turnsInFlight = 0
            releaseTurn()
        }
        if isResult || state.phase != before { host.syncPill(for: self, result: isResult) }
        if case .claude(.result(_, _, false, _)) = event { noticeReply() }
        if case .claude(.permissionRequest(let request)) = event { noticeApproval(request) }
        if case .claude(.permissionMode(let mode)) = event { reportedMode(mode) }
        #if DEBUG
        host.continueDemo(after: event, from: self)
        #endif
        if isResult, restartAfterTurn, state.pendingTurns == 0 {
            restartAfterTurn = false
            discardSession()
        }
        if settled { host.runtimeSettled() }
    }

    // MARK: Permissions

    func answer(_ request: PermissionRequest, _ decision: PermissionDecision) {
        guard state.approvals.contains(where: { $0.id == request.id }), !answering.contains(request.id) else { return }
        guard let active = session else {
            answerFailed("no session")
            return
        }
        answering.insert(request.id)
        let gen = generation
        Task { [weak self] in
            let failure: Error?
            do {
                try await active.respond(to: request, decision)
                failure = nil
            } catch {
                failure = error
            }
            guard let self else { return }
            self.answering.remove(request.id)
            guard gen == self.generation else { return }
            if let failure {
                self.answerFailed(failure.localizedDescription)
            } else {
                ConversationReducer.approvalAnswered(&self.state, id: request.id, decision: decision)
                self.host.syncPill(for: self)
            }
        }
    }

    private func answerFailed(_ reason: String) {
        log.error("permission answer failed: \(reason, privacy: .public)")
        appendSystem("não consegui responder ao claude: a sessão acabou")
    }

    func permissionModeChanged() {
        guard session != nil || startTask != nil else { return }
        if state.pendingTurns == 0 {
            discardSession()
        } else {
            if !restartAfterTurn {
                appendSystem("o novo modo de permissão vale depois desta resposta")
            }
            restartAfterTurn = true
        }
    }

    private func reportedMode(_ mode: String) {
        PermissionModel.shared.sessionReported(mode: mode, requested: sessionMode)
        guard sessionMode == PermissionChoice.auto.rawValue, mode != sessionMode else { return }
        appendSystem("o modo Automático não está disponível nesta conta; esta conversa roda no modo \(mode)")
    }

    private func logLatency() {
        guard let sentAt else { return }
        let elapsed = sentAt.duration(to: .now)
        #if DEBUG
        log.notice("latency: \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)), privacy: .public) phase=\(String(describing: self.state.phase), privacy: .public) status=\(self.state.status ?? "nil", privacy: .public)")
        #endif
        self.sentAt = nil
    }

    // MARK: Record

    private func persist() {
        guard let first = state.messages.first(where: { $0.role == .user }) else { return }
        let last = ConversationPreview.last(of: state.messages)
        let record = ConversationRecord(
            id: id,
            sessionId: state.sessionId,
            title: title ?? ConversationTitle.fallback(from: MessageAttachments.parse(first.text)?.summary ?? first.text),
            updatedAt: Date(),
            cwd: cwd,
            lastPreview: last?.text,
            lastFrom: last?.from,
            titleGenerated: titleGenerated,
            awayOnPhone: awayOnPhone
        )
        title = record.title
        do {
            try host.save(record)
        } catch {
            log.error("conversation upsert failed: \(error.localizedDescription, privacy: .public)")
            appendSystem("não consegui salvar a conversa: \(error.localizedDescription)")
        }
    }

    private func generateTitle() {
        guard !titleRequested,
              let first = state.messages.first(where: { $0.role == .user }),
              let reply = state.messages.first(where: { $0.role == .assistant }) else { return }
        titleRequested = true
        let user = MessageAttachments.parse(first.text)?.summary ?? first.text
        let configured = host.profile.agent.claudePath
        Task { [weak self] in
            let generated = await Task.detached(priority: .utility) { () -> String? in
                guard let executable = try? ClaudeLocator.resolve(configured: configured) else { return nil }
                return ConversationTitle.generate(executable: executable, user: user, reply: reply.text)
            }.value
            guard let self, let generated, self.host?.runtimes[self.id] === self else { return }
            self.titleGenerated = true
            self.title = generated
            self.persist()
        }
    }

    private func mirror(user: String, files: [String]) {
        guard host.telegram.canPost else { return }
        let sessionId = state.sessionId
        let reply = state.messages.last { $0.role == .assistant }?.text ?? ""
        let files = SentFiles.unsent(files + FileLinks.absolutePaths(in: reply), alreadySent: state.sentToTelegram)
        Task {
            let telegram = self.host.telegram
            await telegram.refreshTopicsIfStale()
            guard let post = TelegramTopics.mirror(sessionId: sessionId, topics: telegram.loadedTopics, user: user, reply: reply, files: files),
                  let failure = await telegram.post(post)
            else { return }
            self.log.error("telegram mirror failed: \(failure.sentence, privacy: .public)")
            self.telegramNotice = failure.sentence
        }
    }

    // MARK: Notices

    private func noticeReply() {
        guard let shell = host.shell, let last = state.messages.last, last.role == .assistant else { return }
        shell.notices.post(Notice(
            kind: .reply,
            title: title ?? host.personaName,
            preview: Notices.preview(last.text),
            time: Date(),
            target: linkedThread.map(NoticeTarget.topic) ?? .conversation(id)
        ))
    }

    private func noticeApproval(_ request: PermissionRequest) {
        host.shell?.notices.post(Notice(
            sourceId: "approval:\(id.uuidString)",
            kind: .approval,
            title: "O Claude precisa da tua aprovação",
            preview: Notices.preview("Quer \(request.summary)"),
            time: Date(),
            target: .conversation(id),
            tone: .warning
        ))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
