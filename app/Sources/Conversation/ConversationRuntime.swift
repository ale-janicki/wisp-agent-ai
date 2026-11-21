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
    @ObservationIgnored private var earlierMessages: [ConversationMessage] = []
    @ObservationIgnored private var lastReplyAt: String?
    @ObservationIgnored private var session: (any EngineSession)?
    @ObservationIgnored private var sessionKind: EngineKind?
    @ObservationIgnored private var forgetEngineSession = false
    @ObservationIgnored private var engineLinkReason = "new"
    @ObservationIgnored private var engineNote: String?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingStop: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<any EngineSession, Error>?
    @ObservationIgnored private var historyLoad: UUID?
    @ObservationIgnored private var sentAt: ContinuousClock.Instant?
    @ObservationIgnored private var follower: TranscriptFollower?
    @ObservationIgnored private var followToken = UUID()
    @ObservationIgnored private var sessionMode: String?
    @ObservationIgnored private var answering: Set<String> = []
    @ObservationIgnored private var restartAfterTurn = false
    @ObservationIgnored private var launchedContext: AgentInstructions.Context?
    @ObservationIgnored private var transcriptStore: TranscriptStore?
    @ObservationIgnored private var transcriptKey: String?
    @ObservationIgnored private var linkedSessions: Set<String> = []
    @ObservationIgnored private var primeContext: String?
    @ObservationIgnored private var rebuiltFrom: String?
    @ObservationIgnored private var engineModel: String?
    @ObservationIgnored private var inFlight: [(text: String, user: String)] = []
    private static var transcriptFailureShown = false

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
        TelegramTopics.topic(forSession: state.sessionId, conversation: id, in: host.telegram.loadedTopics)?.thread
    }

    func snapshot(isCurrent: Bool) -> RuntimeSnapshot {
        RuntimeSnapshot(id: id, isCurrent: isCurrent, hasProcess: hasProcess, isBusy: isBusy,
                        hasUnseenReply: unseenReply, lastUsed: lastUsed)
    }

    private func agentContext() -> AgentInstructions.Context {
        AgentInstructions.context(thread: linkedThread, wispBinary: resolvedWispBinary(), agendaBinary: AgendaAccessModel.helperURL.path,
                                  awayOnPhone: awayOnPhone)
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
        TelegramTopics.topic(forSession: sessionId, conversation: id, in: host.telegram.loadedTopics) != nil
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
        isLoadingHistory = true
        let profile = host.profile
        let cwd = expandTilde(record.cwd ?? profile.agent.cwd)
        let prefix = profile.agent.statusPrefix
        let sessionId = record.sessionId
        let conversationKey = record.id.uuidString.lowercased()
        Task { [weak self] in
            let history = await Task.detached { () -> [ConversationMessage]? in
                let store = TranscriptStore(folder: WispFolder.conversations())
                return TranscriptHistory.load(
                    store: store, sessionId: sessionId, conversationKey: conversationKey,
                    claude: { TranscriptReader.load(sessionId: $0, cwd: cwd, statusPrefix: prefix, telegramHTML: true) })
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
        if let topic = TelegramTopics.topic(forSession: state.sessionId, conversation: id, in: host.telegram.loadedTopics) {
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
        earlierMessages = []
        loadEarlierMessages(before: sessionId, cwd: cwd, token: token)
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
        state.messages = earlierMessages + snapshot.messages
        state.status = snapshot.status
    }

    private func loadEarlierMessages(before session: String, cwd: String, token: UUID) {
        let conversation = id.uuidString.lowercased()
        let root = expandTilde(cwd)
        let prefix = host.profile.agent.statusPrefix
        Task { [weak self] in
            let earlier = await Task.detached { () -> [ConversationMessage] in
                TranscriptStore(folder: WispFolder.conversations()).earlierMessages(
                    conversation: conversation, beforeSession: session,
                    claude: { TranscriptReader.load(sessionId: $0, cwd: root, statusPrefix: prefix, telegramHTML: true) })
            }.value
            guard let self, self.followToken == token, !earlier.isEmpty else { return }
            self.earlierMessages = earlier
            if !self.turnRunning, !self.isFailed, !self.state.messages.isEmpty {
                self.state.messages = earlier + self.state.messages
            }
        }
    }

    private func unfollow() {
        follower?.stop()
        follower = nil
        followToken = UUID()
        followedSession = nil
        earlierMessages = []
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
        inFlight = []
        primeContext = nil
        releaseTurn()
        eventTask?.cancel()
        eventTask = nil
        startTask = nil
        ConversationReducer.sessionDiscarded(&state)
        let old = session
        session = nil
        sessionKind = nil
        if let old { chainStop(old) }
    }

    private func restartProcess() {
        generation += 1
        sessionMode = nil
        restartAfterTurn = false
        turnsInFlight = 0
        inFlight = []
        primeContext = nil
        waitingForTelegram = false
        eventTask?.cancel()
        eventTask = nil
        startTask = nil
        ConversationReducer.processRestarted(&state)
        let old = session
        session = nil
        sessionKind = nil
        if let old { chainStop(old) }
    }

    private func chainStop(_ old: any EngineSession) {
        let previous = pendingStop
        pendingStop = Task {
            await previous?.value
            await old.stop()
        }
    }

    private func ensureSession(kind: EngineKind) async throws -> any EngineSession {
        if let session { return session }
        if let startTask { return try await startTask.value }
        let gen = generation
        let task = Task { try await self.startSession(generation: gen, kind: kind) }
        startTask = task
        return try await task.value
    }

    private func startSession(generation gen: Int, kind: EngineKind) async throws -> any EngineSession {
        do {
            await pendingStop?.value
            guard gen == generation else { throw CancellationError() }
            let profile = host.profile
            let configured = profile.agent.claudePath
            let executable = try await Task.detached {
                kind == .codex ? try CodexLocator.resolve(configured: nil) : try ClaudeLocator.resolve(configured: configured)
            }.value
            guard gen == generation else { throw CancellationError() }
            PermissionModel.shared.refresh()
            let mode = PermissionModel.shared.cliMode
            let context = agentContext()
            launchedContext = context
            let resume = prepareResume(kind: kind)
            let launch: EngineLaunch
            switch kind {
            case .claude:
                launch = EngineLaunch(
                    kind: .claude, executable: executable,
                    cwd: URL(fileURLWithPath: expandTilde(cwd ?? profile.agent.cwd)), model: profile.agent.model,
                    resume: resume, claudePermissionMode: mode, instructions: context.prompt,
                    claudeSettingsPath: try guardSettingsPath(), disallowedTools: context.disallowedTools,
                    environment: context.environment)
            case .codex:
                let wispDir = WispFolder.directory().path
                PathsModel.shared.refresh()
                guard let workspace = codexWorkspace() else { throw GuardsUnavailable(reason: ConversationTranscript.noWorkspaceNote) }
                guard let wispBinary = codexWispBinary() else { throw GuardsUnavailable(reason: CodexSession.noWispBinary) }
                launch = EngineLaunch(
                    kind: .codex, executable: executable, cwd: URL(fileURLWithPath: workspace), resume: resume,
                    permission: mode.flatMap(PermissionChoice.init(mode:)),
                    instructions: context.prompt + AgentInstructions.codexNote,
                    addDirs: CodexCommand.extraDirectories(
                        workspace: workspace, candidates: [wispDir, PathsModel.shared.url(.brain).path]),
                    environment: context.environment, wispBinary: wispBinary,
                    preflight: { [environment = CodexCommand.environment(executable: executable, overrides: context.environment)] workspace in
                        CodexReadiness.preflight(wispBinary: wispBinary, environment: environment, workspace: workspace)
                    })
            }
            let next = EngineFactory.make(launch)
            try await next.start()
            if let codex = next as? CodexSession, let problem = await codex.approvalChannelProblem {
                log.error("approval channel for Codex unavailable: \(problem, privacy: .public)")
                appendSystem("não consegui abrir o canal de aprovação do e-mail; nesta conversa o Codex não envia e-mails (\(problem))")
            }
            guard gen == generation else {
                chainStop(next)
                throw CancellationError()
            }
            session = next
            sessionKind = kind
            state.engineName = kind.rawValue
            sessionMode = mode
            startTask = nil
            log.notice("session started engine=\(kind.rawValue, privacy: .public) resume=\(resume ?? "nil", privacy: .private) mode=\(mode ?? "default", privacy: .public)")
            eventTask = Task { [weak self] in
                for await event in next.events { self?.handle(event, generation: gen) }
            }
            return next
        } catch {
            if gen == generation { startTask = nil }
            throw error
        }
    }

    private func prepareResume(kind: EngineKind) -> String? {
        let store = transcript()
        let key = conversationKey(store)
        let plan = EngineResume.plan(
            kind: kind, lastEngine: store.lastEngine(conversation: key), claudeSession: state.sessionId,
            codexSession: store.engineSession(conversation: key, engine: "codex"), lost: forgetEngineSession)
        forgetEngineSession = false
        engineLinkReason = plan.linkReason
        guard plan.prime else { return plan.resume }
        if primeContext == nil { primeContext = store.context(conversation: key) }
        if plan.switched, primeContext != nil { appendSystem(ConversationTranscript.switchedNote(to: kind)) }
        if plan.dropClaudeSession {
            rebuiltFrom = state.sessionId ?? key
            state.sessionId = nil
        }
        return plan.resume
    }

    private func codexWorkspace() -> String? {
        CodexCommand.workspace(
            preferred: expandTilde(cwd ?? host.profile.agent.cwd), wispDir: WispFolder.directory().path)
    }

    private func codexWispBinary() -> String? {
        EngineGuards.wispBinary(
            telegramBinary: host.telegram.wispBinary,
            layout: RuntimeLayout(bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser))
    }

    private func desiredEngine() async -> EngineKind {
        guard EngineChoice.active() == .codex else { return .claude }
        let wisp = codexWispBinary()
        let environment = agentContext().environment
        let workspace = codexWorkspace()
        let readiness = await Task.detached {
            CodexReadiness.check(configured: nil, wispBinary: wisp, environment: environment, workspace: workspace)
        }.value
        guard readiness.ready else {
            if engineNote == nil, sessionKind != .claude { engineNote = readiness.note() }
            return .claude
        }
        guard codexWorkspace() != nil else {
            if engineNote == nil, sessionKind != .claude { engineNote = ConversationTranscript.noWorkspaceNote }
            return .claude
        }
        return .codex
    }

    private func releaseTurn() {
        lastTurnEnded = Date()
        turnLease?.release()
        turnLease = nil
        mirrorUsers = []
        waitingForTelegram = false
    }

    private func adoptTopicSession() {
        guard sessionKind != .codex, turnsInFlight == 0,
              let topic = TelegramTopics.topic(forSession: state.sessionId, conversation: id, in: host.telegram.loadedTopics),
              topic.turns > 0, !topic.sessionId.isEmpty, topic.sessionId != state.sessionId else { return }
        let running = session != nil || startTask != nil
        state.sessionId = topic.sessionId
        if running {
            restartProcess()
            state.phase = .thinking(step: nil)
        }
    }

    private func acquireTurn() async throws -> Bool {
        guard turnLease == nil else { return !Task.isCancelled }
        await host.telegram.refreshTopicsIfStale()
        adoptTopicSession()
        guard let sessionId = state.sessionId else { return !Task.isCancelled }
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

    private func deliver(_ text: String, user: String, record: Bool = true) async {
        guard !Task.isCancelled else { return }
        var gen = generation
        do {
            guard try await acquireTurn() else { return }
            gen = generation
            mirrorUsers.append((user, Self.attachedPaths(text)))
            let kind = await desiredEngine()
            if let sessionKind, sessionKind != kind, turnsInFlight == 0 {
                restartProcess()
                state.phase = .thinking(step: nil)
                gen = generation
            }
            let active = try await ensureSession(kind: sessionKind ?? kind)
            guard gen == generation else { return }
            if let note = engineNote {
                engineNote = nil
                appendSystem(note)
            }
            let outgoing = ConversationTranscript.prime(primeContext, prompt: text)
            primeContext = nil
            if record { recordUser(user) }
            inFlight.append((text, user))
            do {
                try await active.send(outgoing)
            } catch {
                if gen == generation, !inFlight.isEmpty { inFlight.removeLast() }
                throw error
            }
            if gen == generation { turnsInFlight += 1 }
        } catch is CancellationError {
            return
        } catch AgentError.claudeNotFound where EngineChoice.active() == .claude {
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
            state.phase = .failed("não consegui falar com o \((sessionKind ?? EngineChoice.active()).rawValue): \(error.localizedDescription)")
            host.syncPill(for: self)
        }
    }

    // MARK: Events

    private func handle(_ event: SessionEvent, generation gen: Int) {
        guard gen == generation else { return }
        #if DEBUG
        log.notice("event: \(String(String(describing: event).prefix(300)), privacy: .public)")
        #endif
        if case .claude(.result(_, let text, true, _)) = event, ConversationTranscript.isLostSession(text),
           rebuildAfterLostSession() { return }
        let before = state.phase
        ConversationReducer.reduce(&state, event, statusPrefix: host.profile.agent.statusPrefix)
        noteTranscript(event)
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
            if !inFlight.isEmpty { inFlight.removeFirst() }
            let sent = mirrorUsers.isEmpty ? nil : mirrorUsers.removeFirst()
            if !isError, let sent { mirror(user: sent.user, files: sent.files) }
            if state.pendingTurns == 0 { releaseTurn() }
            if !isError, !host.isCurrent(self) { unseenReply = true }
        }
        if case .exited = event {
            settled = true
            turnsInFlight = 0
            inFlight = []
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

    // MARK: Transcript

    private func transcript() -> TranscriptStore {
        let folder = WispFolder.conversations()
        if let transcriptStore, transcriptStore.folder == folder { return transcriptStore }
        let next = TranscriptStore(folder: folder)
        transcriptStore = next
        transcriptKey = nil
        return next
    }

    private func conversationKey(_ store: TranscriptStore) -> String {
        if let transcriptKey { return transcriptKey }
        let key = store.find(session: id.uuidString.lowercased()) ?? store.find(session: state.sessionId) ?? id.uuidString.lowercased()
        transcriptKey = key
        if let sessionId = state.sessionId { linkedSessions.insert(sessionId) }
        return key
    }

    private func record(_ write: (TranscriptStore, String, String?) throws -> Void) {
        let store = transcript()
        let key = conversationKey(store)
        do {
            try write(store, key, state.sessionId)
        } catch {
            log.error("transcript write failed: \(error.localizedDescription, privacy: .public)")
            guard !Self.transcriptFailureShown else { return }
            Self.transcriptFailureShown = true
            appendSystem("não consegui guardar a conversa na pasta do Wisp: \(error.localizedDescription)")
        }
    }

    private func recordUser(_ text: String) {
        record { try $0.appendUser(conversation: $1, openingSession: $2, text: text, surface: "app") }
    }

    private func noteTranscript(_ event: SessionEvent) {
        switch event {
        case .claude(.initialized(let sessionId, let model, _)):
            if !model.isEmpty { engineModel = model }
            linkSession(sessionId)
        case .claude(.engineSession(let engine, let sessionId)):
            linkEngineSession(engine: engine, sessionId: sessionId)
        case .claude(.result(let sessionId, let text, false, _)):
            linkSession(sessionId)
            let body = ReplyFormatter.split(text, statusPrefix: host.profile.agent.statusPrefix).body
            guard !body.isEmpty else { return }
            let model = engineModel
            let engine = sessionKind?.rawValue ?? "claude"
            lastReplyAt = nil
            record { lastReplyAt = try $0.appendAssistant(conversation: $1, openingSession: $2, text: body, surface: "app", engine: engine, model: model) }
        default:
            break
        }
    }

    private func linkSession(_ sessionId: String) {
        guard !sessionId.isEmpty, transcriptKey != nil, !linkedSessions.contains(sessionId) else { return }
        linkedSessions.insert(sessionId)
        let reason = rebuiltFrom == nil ? "new" : "rebuilt"
        rebuiltFrom = nil
        guard sessionId != transcriptKey else { return }
        record { store, key, _ in try store.link(session: sessionId, conversation: key, engine: "claude", reason: reason) }
    }

    private func linkEngineSession(engine: String, sessionId: String) {
        guard !sessionId.isEmpty, transcriptKey != nil, !linkedSessions.contains(sessionId) else { return }
        linkedSessions.insert(sessionId)
        let reason = engineLinkReason
        engineLinkReason = "new"
        record { store, key, _ in try store.link(session: sessionId, conversation: key, engine: engine, reason: reason) }
    }

    private func rebuildAfterLostSession() -> Bool {
        let pending = inFlight
        let store = transcript()
        guard !pending.isEmpty, let lost = state.sessionId,
              let memory = store.context(
                conversation: transcriptKey ?? store.find(session: lost), dropTrailingUsers: pending.count)
        else { return false }
        log.notice("resume lost; rebuilding from the Wisp transcript")
        let kind = sessionKind ?? .claude
        if kind == .claude { state.sessionId = nil }
        discardSession(keepingDeliveries: true)
        primeContext = memory
        if kind == .claude { rebuiltFrom = lost } else { forgetEngineSession = true }
        state.pendingTurns = pending.count
        state.phase = .thinking(step: nil)
        appendSystem(ConversationTranscript.rebuiltNote(engine: kind))
        let previous = deliveryTail
        let deliveryId = UUID()
        let task = Task { [weak self] in
            await previous?.value
            for item in pending { await self?.deliver(item.text, user: item.user, record: false) }
            self?.deliveries[deliveryId] = nil
        }
        deliveries[deliveryId] = task
        deliveryTail = task
        return true
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
        let turnAt = lastReplyAt
        let reply = state.messages.last { $0.role == .assistant }?.text ?? ""
        let files = SentFiles.unsent(files + FileLinks.absolutePaths(in: reply), alreadySent: state.sentToTelegram)
        Task {
            let telegram = self.host.telegram
            await telegram.refreshTopicsIfStale()
            guard let post = TelegramTopics.mirror(
                    sessionId: sessionId, conversation: self.id, topics: telegram.loadedTopics, user: user, reply: reply, files: files,
                    turnAt: turnAt),
                  let failure = await telegram.post(post)
            else { return }
            self.log.error("telegram mirror failed: \(failure.sentence, privacy: .public)")
            self.telegramNotice = failure.retry ? "o Telegram não respondeu; esta conversa chega lá quando ele voltar" : failure.sentence
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
            title: "O \(request.asker) precisa da tua aprovação",
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
