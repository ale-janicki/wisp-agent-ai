import AppKit
import Carbon.HIToolbox
import Foundation
import os
import WispCore

@MainActor
final class MeetingCopilotModel: ObservableObject {
    @Published var assistOn = false {
        didSet { if !assistOn { cancelAssist() } }
    }
    @Published private(set) var assistItems: [AssistItem] = []
    @Published private(set) var assistStatus: String?
    @Published var nudgesOn = false
    @Published private(set) var nudges: [Nudge] = []
    @Published private(set) var stats = MeetingStats(metrics: MeetingMetrics(), ongoing: nil, lastQuestionAt: nil)
    @Published private(set) var bookmarks: [MeetingBookmark] = []
    @Published private(set) var checklist: [ChecklistItem] = []
    @Published var brainOn = false {
        didSet { if !brainOn { brainHits = [] } }
    }
    @Published var brainOthersOn = false
    @Published private(set) var brainAvailable = false
    @Published private(set) var brainHits: [BrainHit] = []
    @Published private(set) var events: [MeetingEvent] = []
    @Published var selectedEventID: String?
    @Published var prepText = ""
    @Published private(set) var prepBusy = false
    @Published private(set) var prepMessage: String?
    @Published private(set) var limitNotice: String?
    @Published private(set) var isLive = false

    private static let tick: Duration = .seconds(1)

    private static func clock() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    private static let statsEvery = 2
    private static let hitLimit = 8
    private static let nudgeLife = 30.0
    private static let searchLimit = 3

    private let log = Logger(subsystem: AppIdentity.bundleID, category: "meetings")
    private let client: MeetingEngineClient
    private var segments: [MeetingSegment] = []
    private var checkedFinals = 0
    private var startedAt: Date?
    private var ticker: Task<Void, Never>?
    private var assistTask: Task<Void, Never>?
    private var prepTask: Task<Void, Never>?
    private var searches: [Task<Void, Never>] = []
    private var assistGate = AssistGate()
    private var nudgeEngine = NudgeEngine()
    private var nudgeShownAt = 0.0
    private var lookupGate = LookupGate()
    private var limitClock = RecordingLimitClock(limit: 0)
    private var brainRoot = ""
    private var onLimit: (@MainActor () -> Void)?
    private var bookmarkKey: HotKey?

    init() {
        client = MeetingEngineClient(layout: RuntimeLayout(bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser))
    }

    var selectedEvent: MeetingEvent? { events.first { $0.id == selectedEventID } }
    var hasPrep: Bool { selectedEvent != nil || !prepText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var liveElapsed: Double { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    static let bookmarkShortcut = "⌃⌥B"

    var transcriptLines: [TranscriptLine] {
        MeetingBookmarks.lines(segments: segments, bookmarks: bookmarks)
    }

    func begin(startedAt now: Date, limitSeconds: Double, brainRoot root: String, onLimit stop: @escaping @MainActor () -> Void) {
        end()
        assistOn = false
        nudgesOn = false
        brainOn = false
        brainOthersOn = false
        startedAt = now
        segments = []
        checkedFinals = 0
        stats = MeetingStats(metrics: MeetingMetrics(), ongoing: nil, lastQuestionAt: nil)
        bookmarks = []
        nudges = []
        nudgeShownAt = 0
        brainHits = []
        assistItems = []
        assistStatus = nil
        limitNotice = nil
        assistGate = AssistGate()
        nudgeEngine = NudgeEngine()
        lookupGate = LookupGate()
        limitClock = RecordingLimitClock(limit: limitSeconds)
        limitClock.start(at: Self.clock())
        brainRoot = root
        onLimit = stop
        isLive = true
        bookmarkKey = HotKey(id: 2, keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.addBookmark()
        }
        probeBrain()
        ticker = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard !Task.isCancelled, let self else { return }
                count += 1
                self.step(everyStats: count % Self.statsEvery == 0)
            }
        }
    }

    func end() {
        ticker?.cancel()
        ticker = nil
        cancelAssist()
        searches.forEach { $0.cancel() }
        searches = []
        bookmarkKey?.unregister()
        bookmarkKey = nil
        onLimit = nil
        isLive = false
        startedAt = nil
        nudges = []
    }

    func takeSnapshot() -> (bookmarks: [MeetingBookmark], checklist: [ChecklistItem]) {
        let snapshot = (bookmarks, checklist)
        bookmarks = []
        checklist = []
        selectedEventID = nil
        prepText = ""
        prepMessage = nil
        segments = []
        return snapshot
    }

    func ingest(_ updated: [MeetingSegment]) {
        guard isLive else { return }
        segments = updated
        let finals = updated.filter(\.isFinal)
        guard finals.count > checkedFinals, brainAvailable, brainOn else {
            checkedFinals = max(checkedFinals, finals.count)
            return
        }
        let fresh = Array(finals[checkedFinals...])
        checkedFinals = finals.count
        lookup(EntityDetector.candidates(in: fresh, includeOthers: brainOthersOn))
    }

    func addBookmark() {
        guard isLive else { return }
        bookmarks.append(MeetingBookmark(time: liveElapsed))
    }

    func toggle(_ item: ChecklistItem) {
        guard let index = checklist.firstIndex(where: { $0.id == item.id }) else { return }
        checklist[index].done.toggle()
    }

    func dismiss(_ nudge: Nudge) {
        nudges.removeAll { $0.id == nudge.id }
    }

    func openHit(_ hit: BrainHit) {
        guard let url = hit.url(root: URL(fileURLWithPath: brainRoot, isDirectory: true)) else { return }
        NSWorkspace.shared.open(url)
    }

    func loadEvents() {
        Task { [weak self, client] in
            let found = await client.todayEvents()
            self?.events = found
            if let id = self?.selectedEventID, !found.contains(where: { $0.id == id }) { self?.selectedEventID = nil }
        }
    }

    func generatePrep() {
        guard hasPrep, !prepBusy else { return }
        prepBusy = true
        prepMessage = nil
        let event = selectedEvent
        let typed = prepText
        prepTask = Task { [weak self, client] in
            do {
                let report = try await client.prep(event: event, description: typed)
                guard let self else { return }
                self.checklist = report.items
                self.prepMessage = report.items.isEmpty ? "O motor não sugeriu nada para esse evento." : nil
            } catch is CancellationError {
            } catch {
                self?.prepMessage = "Não consegui preparar: \(error.localizedDescription)"
            }
            self?.prepBusy = false
        }
    }

    func cancelPrep() {
        prepTask?.cancel()
        prepBusy = false
    }

    private func step(everyStats: Bool) {
        guard isLive else { return }
        switch limitClock.tick(at: Self.clock()) {
        case .warning(let remaining)?:
            limitNotice = "A gravação para sozinha em \(Int((remaining / 60).rounded())) min (limite de tempo ativo)."
        case .reached?:
            onLimit?()
            return
        case nil:
            break
        }
        let elapsed = liveElapsed
        if everyStats {
            stats = MeetingMetricsCalculator.compute(segments, elapsed: elapsed)
            if nudgesOn, let nudge = nudgeEngine.evaluate(stats, elapsed: elapsed) {
                nudges = [nudge]
                nudgeShownAt = elapsed
            } else if !nudges.isEmpty, elapsed - nudgeShownAt > Self.nudgeLife {
                nudges = []
            }
        }
        if assistOn, assistGate.shouldRun(at: elapsed, finalCount: segments.filter(\.isFinal).count) {
            runAssist(elapsed: elapsed)
        }
    }

    private func runAssist(elapsed: Double) {
        let finals = segments.filter(\.isFinal)
        let transcript = AssistTranscript.window(finals, elapsed: elapsed)
        guard !transcript.isEmpty else { return }
        assistGate.started(at: elapsed, finalCount: finals.count)
        assistStatus = "Pensando…"
        let context = MeetingContext.build(event: selectedEvent, description: prepText, checklist: checklist, hits: brainHits)
        let already = assistItems.map(\.text)
        assistTask = Task { [weak self, client] in
            do {
                let items = try await client.assist(transcript: transcript, context: context, already: already)
                guard let self, self.assistOn else { return }
                self.assistItems = AssistReport.merge(items, into: self.assistItems)
                self.assistStatus = nil
            } catch is CancellationError {
            } catch {
                self?.assistStatus = "Sem sugestões agora: \(error.localizedDescription)"
            }
            self?.assistGate.finished()
        }
    }

    private func cancelAssist() {
        assistTask?.cancel()
        assistTask = nil
        assistGate.finished()
        assistStatus = nil
    }

    private func probeBrain() {
        brainAvailable = false
        Task { [weak self, client] in
            let available = await Task.detached { client.brainSearch.isAvailable() }.value
            guard let self, self.isLive else { return }
            self.brainAvailable = available
            self.log.info("brain lookup available: \(available)")
        }
    }

    private func lookup(_ candidates: [String]) {
        let queries = lookupGate.pick(from: candidates, at: liveElapsed)
        guard !queries.isEmpty else { return }
        let root = brainRoot
        let search = client.brainSearch
        let limit = Self.searchLimit
        let task = Task { [weak self] in
            for query in queries {
                let hits = await Task.detached { search.search(query, root: root, limit: limit) }.value
                guard !Task.isCancelled, let self else { return }
                self.mergeHits(hits)
            }
        }
        searches = Array(searches.suffix(8)) + [task]
    }

    private func mergeHits(_ hits: [BrainHit]) {
        let known = Set(brainHits.map(\.path))
        brainHits = Array((hits.filter { !known.contains($0.path) } + brainHits).prefix(Self.hitLimit))
    }
}
