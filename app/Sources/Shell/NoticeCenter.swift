import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class NoticeCenter {
    private(set) var queue = NoticeQueue()
    private(set) var arrivals = 0
    private(set) var unseen: Notice.Tone?

    @ObservationIgnored weak var shell: ShellController?
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var seen = NoticeBaselines()
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "notices")

    private static let pollInterval: Duration = .seconds(60)

    var current: Notice? { queue.current }
    private var settings: NoticeSettings { AppSettings.shared.settings.notices }

    func start() {
        Dashboard.shared.alerts.onLoaded = { [weak self] items in self?.alertsLoaded(items) }
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                await self?.pollSources()
            }
        }
    }

    // MARK: Queue

    func post(_ notice: Notice) {
        let outcome = queue.offer(notice, settings: settings, visible: visible, now: Date())
        log.info("notice \(notice.kind.rawValue, privacy: .public) \(String(describing: outcome), privacy: .public)")
        guard outcome != .suppressed else { return }
        unseen = Self.louder(unseen, notice.tone)
        changed()
    }

    func hover(_ on: Bool) {
        guard on != queue.hovering else { return }
        queue.hover(on, now: Date())
        changed()
    }

    func dismiss() {
        queue.dismiss(now: Date())
        if queue.current == nil { unseen = nil }
        changed()
    }

    func prune() {
        seen.settingsChanged(settings)
        if shell?.state == .panel || settings.doNotDisturb {
            unseen = nil
        }
        let before = queue
        queue.prune(settings: settings, visible: visible, now: Date())
        if queue != before { changed() }
    }

    func open() {
        guard let notice = queue.take(now: Date()) else { return }
        if queue.current == nil { unseen = nil }
        changed()
        shell?.open(notice.target)
    }

    @ObservationIgnored private var shownKey: String?

    private static func louder(_ old: Notice.Tone?, _ new: Notice.Tone) -> Notice.Tone {
        func rank(_ tone: Notice.Tone) -> Int {
            switch tone {
            case .normal: 0
            case .warning: 1
            case .alert: 2
            }
        }
        guard let old else { return new }
        return rank(new) > rank(old) ? new : old
    }

    private func changed() {
        let key = queue.current.map { "\($0.sourceId)|\($0.time.timeIntervalSince1970)" }
        if key != shownKey {
            shownKey = key
            if key != nil { arrivals += 1 }
        }
        schedule()
        onChange()
    }

    private func schedule() {
        timer?.cancel()
        guard let deadline = queue.deadline else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            if self.queue.expire(now: Date()) { self.changed() } else { self.schedule() }
        }
    }

    private var visible: Set<NoticeTarget> {
        guard let shell, shell.state == .panel else { return [] }
        let model = shell.conversation
        switch shell.tab {
        case .conversation:
            var shown: Set<NoticeTarget> = [.conversation(model.currentId)]
            if let thread = model.linkedThread { shown.insert(.topic(thread)) }
            return shown
        case .reminders:
            return [.reminders]
        case .home:
            let tile = AppSettings.shared.settings.dashboardOrder.contains(DashboardTileID.alerts)
            return tile && PanelTab.reminders.isAvailable(in: model.profile) ? [.reminders] : []
        default:
            return []
        }
    }

    // MARK: Sources

    private func pollSources() async {
        guard let shell, shell.state != .panel, !settings.doNotDisturb else { return }
        let model = shell.conversation
        if settings.reminder, let command = model.profile.blocks?.alerts?.list, !command.isEmpty {
            Dashboard.shared.alerts.refresh(command: command)
        }
        if settings.telegram || settings.reply, model.profile.blocks?.telegram?.isComplete == true {
            await model.refreshTelegram()
        }
    }

    private func alertsLoaded(_ items: [AlertItem]) {
        let news = seen.alertsRead(items, settings: settings)
        for item in news.reversed() {
            post(Notice(
                sourceId: "alert:\(item.id)",
                kind: .reminder,
                title: item.level == .red ? "Alerta" : "Lembrete",
                preview: Notices.preview(item.text),
                time: Date(),
                target: .reminders,
                tone: item.level == .red ? .alert : .warning
            ))
        }
    }

    func topicsLoaded(_ topics: [TelegramTopic]?, following: Int?, records: [ConversationRecord], statusPrefix: String?) {
        guard let topics else { return }
        let wispSessions = Set(records.compactMap(\.sessionId))
        let wispThreads = Set(topics.filter { wispSessions.contains($0.sessionId) }.map(\.thread))
        let news = seen.topicsRead(topics, following: following, wispThreads: wispThreads, settings: settings)
        for topic in news {
            let record = records.first { $0.sessionId == topic.sessionId }
            let sessionId = topic.sessionId
            let cwd = expandTilde(topic.cwd)
            Task { [weak self] in
                let last = await Task.detached {
                    TranscriptReader.load(sessionId: sessionId, cwd: cwd, statusPrefix: statusPrefix, telegramHTML: true)?
                        .last { $0.role != .system }?.text
                }.value
                self?.post(Notice(
                    kind: record == nil ? .telegram : .reply,
                    title: record?.title ?? topic.name,
                    preview: Notices.preview(last.flatMap { MessageAttachments.parse($0)?.summary ?? $0 } ?? "Nova mensagem no tópico"),
                    time: Date(),
                    target: .topic(topic.thread)
                ))
            }
        }
    }

    // MARK: Debug

    #if DEBUG
    func setForSnapshot(_ notices: [Notice]) {
        queue = NoticeQueue()
        for notice in notices { queue.offer(notice, settings: NoticeSettings(), visible: [], now: Date()) }
        timer?.cancel()
        queue.hover(true, now: Date())
    }

    func setUnseenForSnapshot(_ tone: Notice.Tone?) { unseen = tone }

    static func samples(persona: String, now: Date = Date()) -> [Notice] {
        [
            Notice(sourceId: "demo:reply", kind: .reply, title: "Planejamento da semana",
                   preview: "Pronto: separei as três entregas de sexta e deixei a revisão do contrato para quinta de manhã.",
                   time: now, target: .conversation(UUID())),
            Notice(sourceId: "demo:telegram", kind: .telegram, title: "Geral",
                   preview: "\(persona): o backup terminou sem erros.", time: now, target: .topic(-1)),
            Notice(sourceId: "demo:alert", kind: .reminder, title: "Alerta",
                   preview: "Renovar o certificado do servidor antes de sexta", time: now, target: .reminders, tone: .alert),
        ]
    }
    #endif
}
