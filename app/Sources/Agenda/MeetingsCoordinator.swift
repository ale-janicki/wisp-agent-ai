import AppKit
import Foundation
import os
@preconcurrency import UserNotifications
import WispCore

@MainActor
final class MeetingsCoordinator: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    static let shared = MeetingsCoordinator()

    private static let category = "WISP_MEETING"
    private static let joinAction = "WISP_JOIN"
    private static let prefix = "wisp.meeting."

    private let log = Logger(subsystem: AppIdentity.bundleID, category: "meetings-alert")
    private var statusItem: NSStatusItem?
    private var ticker: Task<Void, Never>?
    private var events: [CalEvent] = []
    private var calendars: [CalCalendar] = []
    private var scheduledKeys: [String] = []
    private var noticePlan: [MeetingLinks.Alert] = []
    private var noticePlanKey = ""
    private var postedNotices: Set<String> = []
    private var authorization: UNAuthorizationStatus?
    private weak var shell: ShellController?
    private var started = false

    func start(shell: ShellController) {
        guard !started else { return }
        started = true
        self.shell = shell
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [UNNotificationAction(identifier: Self.joinAction, title: "Entrar", options: [.foreground])],
                intentIdentifiers: [])
        ])
        CalendarModel.shared.meetings = shell.meetings
        shell.meetings.contextResolver = { await CalendarModel.shared.meetingContext(at: $0) }
        CalendarModel.shared.start()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await CalendarModel.shared.refreshUpcoming()
                self?.refreshStatusItem()
                self?.postDueNotices()
                for _ in 0..<6 {
                    try? await Task.sleep(for: .seconds(10))
                    self?.refreshStatusItem()
                    self?.postDueNotices()
                }
            }
        }
    }

    func update(events: [CalEvent], calendars: [CalCalendar]) {
        self.events = events
        self.calendars = calendars
        refreshStatusItem()
        replanNotices()
        postDueNotices()
        Task { await scheduleNotifications() }
    }

    private func currentPlan() -> [MeetingLinks.Alert] {
        MeetingLinks.alerts(for: events, now: Date(), leadMinutes: prefs.alertLeadMinutes, earlyMinutes: prefs.earlyAlertMinutes, hideTitles: prefs.hideTitlesInAlerts)
    }

    private var settingsKey: String { "\(prefs.meetingAlerts)|\(prefs.alertLeadMinutes)|\(prefs.earlyAlertMinutes)|\(prefs.hideTitlesInAlerts)" }

    /// The plan is kept between ticks: a recomputed near-start alert is always "one second from now", so it would never come due.
    private func replanNotices() {
        noticePlan = prefs.meetingAlerts
            ? MeetingNoticePlanner.carryOver(old: noticePlan, new: currentPlan(), posted: postedNotices, now: Date())
            : []
        noticePlanKey = settingsKey
        postedNotices = MeetingNoticePlanner.remembered(posted: postedNotices, alerts: noticePlan)
    }

    private func postDueNotices() {
        if settingsKey != noticePlanKey { replanNotices() }
        guard let center = shell?.notices else { return }
        let now = Date()
        for alert in MeetingNoticePlanner.due(alerts: noticePlan, posted: postedNotices, now: now) {
            postedNotices.insert(alert.id)
            center.post(MeetingNoticePlanner.notice(for: alert, now: now))
        }
    }

    /// True when the event was found and had a link to open.
    func join(key: String) async -> Bool {
        var found = events.first { $0.uid == key }
        if found == nil { found = await CalendarModel.shared.eventNamed(key: key) }
        guard let found, MeetingLinks.detect(found) != nil else { return false }
        CalendarModel.shared.join(found)
        return true
    }

    private var prefs: AgendaPreferences { AppSettings.shared.settings.agenda }

    private func refreshStatusItem() {
        let now = Date()
        guard prefs.menuBarNext, CalendarModel.shared.access == .granted,
              let next = events.filter({ !$0.allDay && !$0.declined && $0.end > now && $0.start.timeIntervalSince(now) < 12 * 3_600 })
                .sorted(by: { $0.start < $1.start }).first
        else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            item.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Próxima reunião")
            item.button?.imagePosition = .imageLeading
            statusItem = item
        }
        statusItem?.button?.title = " " + MeetingLinks.menuBarTitle(title: next.title, start: next.start, end: next.end, now: now, hideTitle: prefs.hideTitlesInAlerts)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        guard let next = events.filter({ !$0.allDay && !$0.declined && $0.end > now }).sorted(by: { $0.start < $1.start }).first else { return }
        let header = NSMenuItem(title: MeetingLinks.displayTitle(next.title, hidden: prefs.hideTitlesInAlerts), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let link = MeetingLinks.detect(next) {
            let join = NSMenuItem(title: "Entrar (\(link.provider.name))", action: #selector(joinFromMenu(_:)), keyEquivalent: "")
            join.target = self
            join.representedObject = link.url
            menu.addItem(join)
        }
        let open = NSMenuItem(title: "Abrir na Agenda", action: #selector(openFromMenu(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = next.uid
        menu.addItem(open)
    }

    @objc private func joinFromMenu(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        openEvent(key: key)
    }

    func openEvent(key: String) {
        guard let shell else { return }
        shell.tab = .agenda
        shell.pillClicked()
        Task {
            var found = events.first { $0.uid == key }
            if found == nil { found = await CalendarModel.shared.eventNamed(key: key) }
            if let found { CalendarModel.shared.reveal(found) }
        }
    }

    private func scheduleNotifications() async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        guard prefs.meetingAlerts, prefs.systemMeetingNotifications else {
            if !existing.isEmpty { center.removePendingNotificationRequests(withIdentifiers: existing) }
            scheduledKeys = []
            return
        }
        let plan = currentPlan()
        let signature = plan.map { "\($0.id)|\($0.fireDate.timeIntervalSince1970)|\($0.title)" }
        guard signature != scheduledKeys else { return }
        guard await ensureAuthorization() else { return }
        center.removePendingNotificationRequests(withIdentifiers: existing)
        for alert in plan {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            let minutes = max(0, Int((alert.start.timeIntervalSince(alert.fireDate) / 60).rounded()))
            content.body = minutes == 0 ? "Começando agora" : "Começa em \(minutes) min"
            if !alert.early { content.categoryIdentifier = Self.category }
            content.sound = .default
            content.userInfo = ["url": alert.url.absoluteString, "key": alert.key]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, alert.fireDate.timeIntervalSinceNow), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: Self.prefix + alert.id, content: content, trigger: trigger))
            } catch {
                log.error("notification not scheduled: \(error.localizedDescription, privacy: .public)")
            }
        }
        scheduledKeys = signature
    }

    private func ensureAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        if authorization == nil { authorization = await center.notificationSettings().authorizationStatus }
        if authorization == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            authorization = granted ? .authorized : .denied
        }
        return authorization == .authorized || authorization == .provisional
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        let key = info["key"] as? String
        await MainActor.run {
            if action == Self.joinAction, let url {
                NSWorkspace.shared.open(url)
            } else if action == UNNotificationDefaultActionIdentifier, let key {
                self.openEvent(key: key)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
