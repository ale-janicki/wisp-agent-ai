import AppKit
import Foundation
import Observation
import os
import SwiftUI
import WispCore

@MainActor @Observable
final class CalendarModel {
    static let shared = CalendarModel()

    enum Detail: Equatable {
        case event(CalEvent)
        case draft(EventDraft)
    }

    struct PendingScope: Equatable {
        enum Action: Equatable {
            case edit(EventEdit)
            case delete
        }
        let event: CalEvent
        let action: Action
    }

    static let hourHeight: Double = 48
    static let chunkDays = 31
    static let dayReach = 1_500

    let backend: any CalendarBackend
    let editor: CalendarEditor
    let links = EventLinkStore(url: EventLinkStore.defaultURL)

    private(set) var access: AgendaAccess
    private(set) var calendars: [CalCalendar] = []
    private(set) var index: EventIndex
    private(set) var revision = 0
    private(set) var loading = false
    private(set) var canUndo = false
    private(set) var reminders: [AgendaReminder] = []
    private(set) var remindersAccess: AgendaAccess = .notDetermined
    private(set) var remindersBusy = false

    var message: String?
    var mode: CalendarViewMode
    var leftDay: Int?
    var topWeek: Int?
    var selection: String?
    var detail: Detail?
    var pendingScope: PendingScope?
    var pendingDelete: CalEvent?
    var searchOpen = false
    var searchQuery = ""
    var quickOpen = false
    var quickText = ""
    var availabilityOn = false
    var availabilitySlots: [DateInterval] = []
    var sidebarOpen: Bool
    var creating: (day: Int, startY: Double, endY: Double)?
    var meetings: MeetingRecordingModel?
    var brainRoot: String?
    var upcoming: (event: CalEvent, link: MeetingLink)?

    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "calendar")
    @ObservationIgnored private var loadedChunks = Set<Int>()
    @ObservationIgnored private var loadingChunks = Set<Int>()
    @ObservationIgnored private var settledChunks = Set<Int>()
    @ObservationIgnored private var failedChunks = Set<Int>()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private var prefetch: Task<Void, Never>?
    @ObservationIgnored private let reminderStore = EventKitStore()
    @ObservationIgnored private var visibleWindow: ClosedRange<Int>?

    let calendar: Calendar

    init(backend: any CalendarBackend = EventKitCalendarBackend()) {
        self.backend = backend
        editor = CalendarEditor(backend: backend)
        var cal = Calendar.current
        cal.timeZone = .current
        calendar = cal
        index = EventIndex(calendar: cal)
        access = backend.eventsAccess()
        let prefs = AppSettings.shared.settings.agenda
        mode = prefs.mode
        sidebarOpen = prefs.showSidebar
        remindersAccess = reminderStore.access(for: .reminders)
    }

    var prefs: AgendaPreferences { AppSettings.shared.settings.agenda }
    var zone: TimeZone { calendar.timeZone }
    var todayNumber: Int { index.dayNumber(Date()) }
    var dayBounds: ClosedRange<Int> { (todayNumber - Self.dayReach)...(todayNumber + Self.dayReach) }
    var visibleCalendarIDs: Set<String> { prefs.visibleCalendarIDs(calendars) }

    func calendarInfo(_ id: String) -> CalCalendar? { calendars.first { $0.id == id } }

    func color(for event: CalEvent) -> Color {
        Color(hex: calendarInfo(event.calendarID)?.colorHex ?? 0x60A5FA)
    }

    func events(onDay day: Int) -> [CalEvent] {
        _ = revision
        let visible = visibleCalendarIDs
        return index.events(onDay: day).filter { visible.contains($0.calendarID) || calendars.isEmpty }
    }

    func isPending(day: Int) -> Bool {
        _ = revision
        _ = loading
        let chunk = Self.chunk(of: day)
        return access == .granted && !settledChunks.contains(chunk) && !failedChunks.contains(chunk)
    }

    func start() {
        access = backend.eventsAccess()
        guard access == .granted else { return }
        if watcher == nil {
            watcher = Task { [weak self] in
                guard let stream = self?.backend.changes() else { return }
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    self?.storeChanged()
                }
            }
        }
        Task { await refreshCalendars() }
        if leftDay == nil { leftDay = weekStart(of: todayNumber) }
        if topWeek == nil { topWeek = weekStart(of: todayNumber) }
    }

    func requestAccess() {
        Task {
            _ = await backend.requestEventsAccess()
            access = backend.eventsAccess()
            AgendaAccessModel.shared.refresh()
            start()
        }
    }

    func openPrivacyPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
    }

    func openInternetAccounts() {
        let urls = ["x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension", "x-apple.systempreferences:com.apple.preferences.internetaccounts"]
        for raw in urls { if let url = URL(string: raw), NSWorkspace.shared.open(url) { return } }
    }

    var showsGoogleHint: Bool {
        guard access == .granted, !calendars.isEmpty, !prefs.googleHintDismissed else { return false }
        return !calendars.contains { ($0.sourceTitle + " " + $0.title).localizedCaseInsensitiveContains("google") || $0.sourceTitle.localizedCaseInsensitiveContains("gmail") }
    }

    func dismissGoogleHint() { AppSettings.shared.setAgenda { $0.googleHintDismissed = true } }

    func refreshCalendars() async {
        calendars = await backend.calendars().sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
        revision += 1
    }

    var sources: [(id: String, title: String, calendars: [CalCalendar])] {
        Dictionary(grouping: calendars, by: \.sourceID)
            .map { (id: $0.key, title: $0.value.first?.sourceTitle ?? "", calendars: $0.value) }
            .sorted { $0.title < $1.title }
    }

    func setCalendar(_ calendar: CalCalendar, visible: Bool) {
        AppSettings.shared.setAgenda { prefs in
            if visible { prefs.hiddenCalendars.remove(calendar.id) } else { prefs.hiddenCalendars.insert(calendar.id) }
        }
        revision += 1
    }

    func setSource(_ id: String, visible: Bool) {
        AppSettings.shared.setAgenda { prefs in
            if visible { prefs.hiddenSources.remove(id) } else { prefs.hiddenSources.insert(id) }
        }
        revision += 1
    }

    func sourceVisible(_ id: String) -> Bool { !prefs.hiddenSources.contains(id) }

    func setMode(_ new: CalendarViewMode) {
        let anchor = anchorDay
        mode = new
        AppSettings.shared.setAgenda { $0.mode = new }
        switch new {
        case .day: leftDay = anchor
        case .week: leftDay = weekStart(of: anchor)
        case .month: topWeek = weekStart(of: anchor)
        case .schedule: scheduleStart = anchor
        }
    }

    var scheduleStart: Int = 0

    var visibleDays: Int { mode == .day ? 1 : 7 }

    var anchorDay: Int {
        switch mode {
        case .day: leftDay ?? todayNumber
        case .week: (leftDay ?? todayNumber) + 3
        case .month: (topWeek ?? todayNumber) + 10
        case .schedule: scheduleStart == 0 ? todayNumber : scheduleStart
        }
    }

    func weekStart(of day: Int) -> Int {
        let date = index.date(forDayNumber: day)
        let weekday = calendar.component(.weekday, from: date)
        let back = (weekday - calendar.firstWeekday + 7) % 7
        return day - back
    }

    func goToday() {
        withAnimation(.easeInOut(duration: 0.25)) {
            switch mode {
            case .day: leftDay = todayNumber
            case .week: leftDay = weekStart(of: todayNumber)
            case .month: topWeek = weekStart(of: todayNumber)
            case .schedule: scheduleStart = todayNumber
            }
        }
        scheduleJump += 1
    }

    var scheduleJump = 0

    func step(_ direction: Int) {
        withAnimation(.easeInOut(duration: 0.25)) {
            switch mode {
            case .day: leftDay = (leftDay ?? todayNumber) + direction
            case .week: leftDay = (leftDay ?? todayNumber) + 7 * direction
            case .month: topWeek = (topWeek ?? todayNumber) + 7 * 5 * direction
            case .schedule:
                scheduleStart = anchorDay + 7 * direction
                scheduleJump += 1
            }
        }
    }

    func focus(day: Int, mode newMode: CalendarViewMode) {
        mode = newMode
        AppSettings.shared.setAgenda { $0.mode = newMode }
        switch newMode {
        case .day: leftDay = day
        case .week: leftDay = weekStart(of: day)
        case .month: topWeek = weekStart(of: day)
        case .schedule: scheduleStart = day
        }
    }

    var title: String {
        let date = index.date(forDayNumber: anchorDay)
        let style = Date.FormatStyle().locale(Locale(identifier: "pt_BR"))
        switch mode {
        case .day: return Self.sentenceCase(date.formatted(style.weekday(.wide).day().month(.wide)))
        default: return Self.sentenceCase(date.formatted(style.month(.wide).year()))
        }
    }

    static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    func ensureLoaded(days: ClosedRange<Int>) {
        guard access == .granted else { return }
        visibleWindow = days
        let first = Self.chunk(of: days.lowerBound), last = Self.chunk(of: days.upperBound)
        let wanted = Array(first...last).filter { !loadedChunks.contains($0) && !loadingChunks.contains($0) }
        guard !wanted.isEmpty else { return }
        fetch(chunks: wanted)
        schedulePrefetch(around: days)
    }

    private static func chunk(of day: Int) -> Int { Int((Double(day) / Double(chunkDays)).rounded(.down)) }

    private func fetch(chunks: [Int]) {
        var groups: [[Int]] = []
        for chunk in chunks.sorted() {
            if var last = groups.last, last.last == chunk - 1, last.count < 4 {
                last.append(chunk)
                groups[groups.count - 1] = last
            } else {
                groups.append([chunk])
            }
        }
        for group in groups {
            loadingChunks.formUnion(group)
            loading = true
            let lower = group[0] * Self.chunkDays, upper = (group[group.count - 1] + 1) * Self.chunkDays
            let current = generation
            Task { [weak self] in
                guard let self else { return }
                let start = self.index.date(forDayNumber: lower), end = self.index.date(forDayNumber: upper)
                let found = try? await self.backend.events(from: start, to: end)
                guard self.generation == current else {
                    self.loadingChunks.subtract(group)
                    self.loading = !self.loadingChunks.isEmpty
                    return
                }
                self.loadingChunks.subtract(group)
                if let found {
                    self.index.replace(range: lower..<upper, with: found)
                    self.loadedChunks.formUnion(group)
                    self.settledChunks.formUnion(group)
                    self.failedChunks.subtract(group)
                    self.revision += 1
                } else {
                    self.failedChunks.formUnion(group)
                    self.revision += 1
                    self.message = "Não consegui ler a agenda."
                }
                self.loading = !self.loadingChunks.isEmpty
            }
        }
    }

    private func schedulePrefetch(around days: ClosedRange<Int>) {
        prefetch?.cancel()
        prefetch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let center = (days.lowerBound + days.upperBound) / 2
            let span = 183
            let range = (center - span)...(center + span)
            let missing = Array(Self.chunk(of: range.lowerBound)...Self.chunk(of: range.upperBound))
                .filter { !self.loadedChunks.contains($0) && !self.loadingChunks.contains($0) }
            if !missing.isEmpty { self.fetch(chunks: missing) }
        }
    }

    private func storeChanged() {
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.invalidate()
        }
    }

    func invalidate() {
        generation += 1
        loadedChunks = []
        loadingChunks = []
        Task { await refreshCalendars() }
        if let window = visibleWindow { ensureLoaded(days: window) }
        if let selected = selection, case .event(let event)? = detail {
            Task { [weak self] in
                guard let self else { return }
                if let fresh = try? await self.backend.event(ref: event.ref) { self.detail = .event(fresh) } else if selected == event.uid { self.detail = nil }
            }
        }
        Task { await refreshUpcoming() }
        Task { await refreshReminders() }
    }

    func refreshUpcoming() async {
        if access != .granted {
            access = backend.eventsAccess()
            if access == .granted { start() }
        }
        guard access == .granted else { return }
        let now = Date()
        let found = (try? await backend.events(from: now.addingTimeInterval(-3_600), to: now.addingTimeInterval(48 * 3_600))) ?? []
        let visible = visibleCalendarIDs
        let usable = found.filter { visible.contains($0.calendarID) || calendars.isEmpty }
        upcoming = MeetingLinks.next(in: usable, now: now).map { ($0.event, $0.link) }
        MeetingsCoordinator.shared.update(events: usable, calendars: calendars)
    }

    func meetingContext(at start: Date) async -> MeetingEventContext? {
        access = backend.eventsAccess()
        guard access == .granted else { return nil }
        let found = (try? await backend.events(from: start.addingTimeInterval(-86_400), to: start.addingTimeInterval(86_400))) ?? []
        let visible = visibleCalendarIDs
        let usable = found.filter { visible.contains($0.calendarID) || calendars.isEmpty }
        let window = start.addingTimeInterval(MeetingEventMatcher.lookahead)
        guard let event = MeetingEventMatcher.pick(events: usable, from: start, to: window) else { return nil }
        return MeetingEventContext(event: event, calendarTitle: calendarInfo(event.calendarID)?.title, links: links)
    }

    func select(_ event: CalEvent) {
        selection = event.uid
        detail = .event(event)
    }

    func closeDetail() {
        detail = nil
        selection = nil
    }

    func eventNamed(key: String) async -> CalEvent? {
        let now = Date()
        let found = try? await backend.events(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(14 * 86_400))
        return found?.first { $0.uid == key }
    }

    func reveal(_ event: CalEvent) {
        focus(day: index.dayNumber(event.start), mode: mode == .month || mode == .schedule ? mode : .week)
        select(event)
        ensureLoaded(days: (index.dayNumber(event.start) - 7)...(index.dayNumber(event.start) + 7))
    }

    func newDraft(day: Int, startMinute: Int, endMinute: Int) {
        let date = index.date(forDayNumber: day)
        guard let span = GridMath.span(onDay: date, startMinute: startMinute, endMinute: endMinute, calendar: calendar) else { return }
        let writable = calendars.first { $0.writable && visibleCalendarIDs.contains($0.id) }
        detail = .draft(EventDraft(title: "", start: span.start, end: span.end, calendarID: writable?.id,
                                   alarmOffsets: []))
        selection = nil
    }

    func newAllDayDraft(day: Int) {
        let date = index.date(forDayNumber: day)
        let writable = calendars.first { $0.writable && visibleCalendarIDs.contains($0.id) }
        detail = .draft(EventDraft(title: "", start: calendar.startOfDay(for: date),
                                   end: CalendarDates.allDayEnd(lastDay: date, calendar: calendar), allDay: true, calendarID: writable?.id))
    }

    func commitDraft(_ draft: EventDraft) {
        var draft = draft
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty { draft.title = "Sem título" }
        Task {
            do {
                let made = try await editor.create(draft)
                await afterWrite()
                detail = .event(made)
                selection = made.uid
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func quickPreview() -> QuickEvent? {
        QuickEventParser.parse(quickText, now: Date(), calendar: calendar, calendarNames: calendars.filter(\.writable).map(\.title))
    }

    func commitQuick() {
        guard let parsed = quickPreview() else { return }
        let target = parsed.calendarName.flatMap { name in
            calendars.first { $0.writable && $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        if parsed.calendarName != nil, target == nil {
            message = "Não achei um calendário editável chamado \"\(parsed.calendarName ?? "")\"."
            return
        }
        let fallback = target ?? calendars.first { $0.writable && visibleCalendarIDs.contains($0.id) }
        let draft = EventDraft(title: parsed.title.isEmpty ? "Sem título" : parsed.title, start: parsed.start, end: parsed.end, allDay: parsed.allDay,
                               calendarID: fallback?.id, location: parsed.location)
        quickText = ""
        quickOpen = false
        Task {
            do {
                let made = try await editor.create(draft)
                await afterWrite()
                focus(day: index.dayNumber(made.start), mode: mode)
                select(made)
                message = "Criado: \(made.title)"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func afterWrite() async {
        canUndo = await editor.canUndo
        invalidate()
    }

    func edit(_ event: CalEvent, _ change: EventEdit, scope: RecurrenceScope? = nil) {
        guard event.writable else {
            message = "\"\(calendarInfo(event.calendarID)?.title ?? event.title)\" é somente leitura."
            return
        }
        if RecurrenceScope.needsChoice(for: event), scope == nil {
            pendingScope = PendingScope(event: event, action: .edit(change))
            return
        }
        patchLocally(event, change)
        Task {
            do {
                let updated = try await editor.update(event, edit: change, scope: scope)
                if case .event(let shown)? = detail, shown.uid == event.uid { detail = .event(updated); selection = updated.uid }
            } catch {
                message = error.localizedDescription
            }
            await afterWrite()
        }
    }

    func move(_ event: CalEvent, deltaMinutes: Double, deltaDays: Int) {
        let span = GridMath.move(TimeSpan(start: event.start, end: event.end), deltaMinutes: deltaMinutes, deltaDays: deltaDays, calendar: calendar)
        guard span.start != event.start else { return }
        edit(event, EventEdit(start: span.start, end: span.end))
    }

    func moveAllDay(_ event: CalEvent, deltaDays: Int) {
        guard deltaDays != 0, let start = calendar.date(byAdding: .day, value: deltaDays, to: event.start),
              let end = calendar.date(byAdding: .day, value: deltaDays, to: event.end) else { return }
        edit(event, EventEdit(start: start, end: end))
    }

    func resize(_ event: CalEvent, edge: Edge.Set, deltaMinutes: Double) {
        let span = TimeSpan(start: event.start, end: event.end)
        let changed = edge == .top
            ? GridMath.resizeStart(span, deltaMinutes: deltaMinutes, calendar: calendar)
            : GridMath.resizeEnd(span, deltaMinutes: deltaMinutes, calendar: calendar)
        guard changed != span else { return }
        edit(event, EventEdit(start: edge == .top ? changed.start : nil, end: edge == .top ? nil : changed.end))
    }

    func delete(_ event: CalEvent, scope: RecurrenceScope? = nil) {
        guard event.writable else {
            message = "\"\(calendarInfo(event.calendarID)?.title ?? event.title)\" é somente leitura."
            return
        }
        if RecurrenceScope.needsChoice(for: event), scope == nil {
            pendingScope = PendingScope(event: event, action: .delete)
            return
        }
        Task {
            do {
                try await editor.delete(event, scope: scope)
                if selection == event.uid { closeDetail() }
            } catch {
                message = error.localizedDescription
            }
            await afterWrite()
        }
    }

    func resolve(_ scope: RecurrenceScope) {
        guard let pending = pendingScope else { return }
        pendingScope = nil
        switch pending.action {
        case .edit(let change): edit(pending.event, change, scope: scope)
        case .delete: delete(pending.event, scope: scope)
        }
    }

    func requestDelete(_ event: CalEvent) {
        guard event.writable else {
            message = "\"\(calendarInfo(event.calendarID)?.title ?? event.title)\" é somente leitura."
            return
        }
        pendingDelete = event
    }

    func confirmDelete() {
        guard let event = pendingDelete else { return }
        pendingDelete = nil
        delete(event)
    }

    func deleteSelected() {
        guard case .event(let event)? = detail else { return }
        requestDelete(event)
    }

    func undo() {
        Task {
            do {
                if let result = try await editor.undo() { message = result.message }
            } catch {
                message = "Não consegui desfazer: \(error.localizedDescription)"
            }
            await afterWrite()
        }
    }

    private func patchLocally(_ event: CalEvent, _ change: EventEdit) {
        var changed = event
        if let start = change.start { changed.start = start }
        if let end = change.end { changed.end = end }
        if let title = change.title { changed.title = title }
        guard changed != event, !event.isRecurring else { return }
        let low = min(index.dayNumber(event.start), index.dayNumber(changed.start)) - 1
        let high = max(index.dayNumber(event.end), index.dayNumber(changed.end)) + 1
        for day in low...high {
            let before = index.events(onDay: day)
            guard before.contains(where: { $0.uid == event.uid }) || (index.dayNumber(changed.start)...max(index.dayNumber(changed.start), index.dayNumber(changed.end))).contains(day) else { continue }
            var replaced = before.filter { $0.uid != event.uid }
            if (index.dayNumber(changed.start)...max(index.dayNumber(changed.start), index.dayNumber(changed.end))).contains(day) { replaced.append(changed) }
            index.replace(range: day..<(day + 1), with: [])
            index.replace(range: day..<(day + 1), with: replaced)
        }
        revision += 1
    }

    func search() -> [CalEvent] {
        let needle = searchQuery.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        var seen = Set<String>()
        var found: [CalEvent] = []
        for (_, events) in index.byDay {
            for event in events where seen.insert(event.uid).inserted {
                let hay = [event.title, event.location ?? "", event.notes ?? ""].joined(separator: "\n")
                if hay.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil { found.append(event) }
            }
        }
        return found.filter { visibleCalendarIDs.contains($0.calendarID) }.sorted { $0.start < $1.start }
    }

    func loadForSearch() {
        let today = todayNumber
        ensureLoaded(days: (today - 365)...(today + 365))
    }

    func toggleSidebar() {
        sidebarOpen.toggle()
        AppSettings.shared.setAgenda { $0.showSidebar = sidebarOpen }
    }

    func refreshReminders() async {
        remindersAccess = reminderStore.access(for: .reminders)
        guard remindersAccess == .granted else { return }
        remindersBusy = true
        let service = AgendaService(store: reminderStore, timeZone: zone)
        let outcome = await service.run(arguments: ["lembretes", "--pendentes"])
        remindersBusy = false
        guard outcome.exitCode == 0 else { return }
        reminders = ReminderList.dueByToday(ReminderList.parse(Data(outcome.stdout.utf8), timeZone: zone), now: Date(), calendar: calendar)
    }

    func requestRemindersAccess() {
        Task {
            _ = await reminderStore.requestAccess(for: .reminders)
            await refreshReminders()
        }
    }

    func complete(_ reminder: AgendaReminder) {
        reminders.removeAll { $0.id == reminder.id }
        let service = AgendaService(store: reminderStore, timeZone: zone)
        Task {
            let outcome = await service.run(arguments: ["concluir-lembrete", reminder.id])
            if outcome.exitCode != 0 { message = outcome.stderr }
            await refreshReminders()
        }
    }

    func generateAvailability() {
        let first = index.date(forDayNumber: leftDay.map { mode == .day ? $0 : weekStart(of: $0) } ?? todayNumber)
        let days = mode == .day ? 1 : 7
        let range = (index.dayNumber(first))...(index.dayNumber(first) + days)
        ensureLoaded(days: range)
        var busy: [CalEvent] = []
        for day in range { busy += events(onDay: day) }
        var seen = Set<String>()
        busy = busy.filter { seen.insert($0.uid).inserted }
        availabilitySlots = Availability.freeSlots(from: first, days: days, busy: Availability.busyIntervals(from: busy), hours: prefs.workingHours,
                                                   calendar: calendar, now: Date())
    }

    func addAvailabilitySlot(day: Int, startMinute: Int, endMinute: Int) {
        guard let span = GridMath.span(onDay: index.date(forDayNumber: day), startMinute: startMinute, endMinute: endMinute, calendar: calendar) else { return }
        availabilitySlots = Availability.merged(availabilitySlots + [DateInterval(start: span.start, end: span.end)])
    }

    func removeAvailabilitySlot(_ slot: DateInterval) {
        availabilitySlots.removeAll { $0 == slot }
    }

    var availabilityText: String {
        Availability.text(availabilitySlots, zone: zone, language: prefs.availabilityLanguage, at: Date())
    }

    func copyAvailability() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(availabilityText, forType: .string)
        message = "Horários copiados."
    }

    func brainLinks(for event: CalEvent) -> [String] {
        var names = BrainLinks.wikilinks(in: event.notes)
        if let path = links.link(for: event.uid)?.notePath {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    func openBrainNote(_ name: String) {
        guard let root = brainRoot, let url = MemorySearch.obsidianURL(root: root, path: name), NSWorkspace.shared.open(url) else {
            message = "Não consegui abrir a nota no Obsidian; confira se ele está instalado e se o cérebro está configurado."
            return
        }
    }

    func createMeetingNote(for event: CalEvent) {
        guard let root = brainRoot else {
            message = "Configure a pasta do cérebro em Ajustes para criar notas."
            return
        }
        let calendarTitle = calendarInfo(event.calendarID)?.title
        let zone = event.timeZone ?? self.zone
        let folder = links.link(for: event.uid)?.recordingFolder
        Task {
            let outcome = await Task.detached {
                Result { try MeetingNote.create(for: event, calendarTitle: calendarTitle, brainRoot: root, zone: zone, recordingFolder: folder) }
            }.value
            switch outcome {
            case .failure(let error):
                message = "Não consegui criar a nota: \(error.localizedDescription)"
            case .success(let note):
                try? links.upsert(EventLink(key: event.uid, title: event.title, eventStart: event.start, calendar: calendarTitle,
                                            notePath: note.relativePath))
                if event.writable {
                    edit(event, EventEdit(notes: MeetingNote.appendingLink(to: event.notes, name: note.name)), scope: event.isRecurring ? .thisOnly : nil)
                }
                message = note.created ? "Nota criada em meetings." : "A nota já existia."
                openBrainNote(note.name)
            }
        }
    }

    func recordAndTranscribe(_ event: CalEvent) {
        guard let meetings else {
            message = "A gravação não está disponível agora."
            return
        }
        guard meetings.phase == .idle else {
            message = meetings.isRecording ? "Já tem uma gravação em andamento." : "Aguarde a gravação atual terminar."
            return
        }
        meetings.start(linkedTo: MeetingEventContext(event: event, calendarTitle: calendarInfo(event.calendarID)?.title, links: links))
        if let link = MeetingLinks.detect(event) { NSWorkspace.shared.open(link.url) }
        message = "Gravando: \(event.title)"
    }

    func join(_ event: CalEvent) {
        guard let link = MeetingLinks.detect(event) else { return }
        NSWorkspace.shared.open(link.url)
    }

    func joinNext() {
        Task {
            await refreshUpcoming()
            guard let next = upcoming else {
                message = "Nenhuma reunião com link por perto."
                return
            }
            NSWorkspace.shared.open(next.link.url)
        }
    }

    func setSecondaryZones(_ zones: [String]) {
        AppSettings.shared.setAgenda { $0.secondaryZones = zones }
    }

    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !press.modifiers.contains(.command), !press.modifiers.contains(.control) else { return .ignored }
        switch press.key {
        case .leftArrow, .upArrow: step(-1)
        case .rightArrow, .downArrow: step(1)
        case .delete, .deleteForward: deleteSelected()
        case .escape:
            if detail != nil { closeDetail() } else if quickOpen { quickOpen = false } else if searchOpen { searchOpen = false } else { return .ignored }
        default:
            switch press.characters.lowercased() {
            case "t": goToday()
            case "j": step(1)
            case "k": step(-1)
            case "d": setMode(.day)
            case "w": setMode(.week)
            case "m": setMode(.month)
            case "a": setMode(.schedule)
            case "/": searchOpen = true; loadForSearch()
            case "n": quickOpen = true
            default: return .ignored
            }
        }
        return .handled
    }
}

extension CalendarModel {
    var allDayRows: Int {
        let first = leftDay ?? todayNumber
        let counts = (first..<(first + visibleDays)).map { events(onDay: $0).filter(\.allDay).count }
        return min(counts.max() ?? 0, 3)
    }
}
