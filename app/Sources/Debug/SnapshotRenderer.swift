#if DEBUG
import AppKit
import SwiftUI
import WispCore

@MainActor
enum SnapshotRenderer {
    static func directory(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "-WispSnapshot"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func run(into directory: URL) async {
        let shell = ShellController()
        shell.media.start()
        shell.media.refresh()
        let dashboard = Dashboard.shared
        dashboard.usage.refreshIfStale()
        if let command = shell.conversation.profile.blocks?.alerts?.list {
            dashboard.alerts.refresh(command: command)
        }
        let started = Date()
        try? await Task.sleep(for: .seconds(2))
        for _ in 0..<100 where dashboard.usage.summary == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("snapshot: usage ready after \(String(format: "%.2f", Date().timeIntervalSince(started)))s total=\(dashboard.usage.summary?.totalTokens ?? -1) today=\(dashboard.usage.summary?.today.totalTokens ?? -1)")
        print("snapshot: alerts \(dashboard.alerts.state)")
        print("snapshot: automation \(MediaPlayer.allCases.map { "\($0.name)=\(shell.media.automationStatus(for: $0))" })")
        guard let layout = shell.snapshotLayout() else {
            print("snapshot: no screen")
            return
        }
        let notch = layout.notch
        if ProcessInfo.processInfo.arguments.contains("-WispSnapshotGraph") {
            await renderMemoryGraph(shell, layout: layout, to: directory)
            return
        }

        shell.setSnapshotState(.rest, notch: notch)
        await render(shell, frame: layout.rest, notch: notch, to: directory, name: "1-pill-rest")

        let previousText = shell.pillText
        let previousColor = shell.statusColor
        shell.pillText = "\(shell.conversation.personaName) pensando…"
        shell.statusColor = .busy
        shell.setSnapshotState(.active, notch: notch)
        await render(shell, frame: layout.active, notch: notch, to: directory, name: "2-pill-active")
        shell.pillText = previousText
        shell.statusColor = previousColor

        shell.setSnapshotState(.panel, notch: notch)
        shell.tab = .home
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "3-panel-home-fresh")
        shell.tab = .settings
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "7-panel-settings")
        let saved = AppSettings.shared.settings
        AppSettings.shared.applyForSnapshot(WispSettings(
            theme: WispSettings.customTheme,
            custom: CustomTheme(accent: HexColor(0xF472B6), background: HexColor(0x0D1117), surface: HexColor(0x161B22))
        ))
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "8-panel-settings-custom")
        shell.tab = .home
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "9-panel-home-custom")
        AppSettings.shared.applyForSnapshot(saved)
        var reordered = saved
        reordered.dashboardOrder = [DashboardTileID.conversation, DashboardTileID.alerts, DashboardTileID.music, DashboardTileID.usage]
        AppSettings.shared.applyForSnapshot(reordered)
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "10-panel-home-reordered")
        AppSettings.shared.applyForSnapshot(saved)

        if let latest = shell.conversation.records.first {
            shell.conversation.open(latest)
            for _ in 0..<50 where shell.conversation.isLoadingHistory {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        shell.tab = .home
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "4-panel-home")
        shell.tab = .conversation
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "5-panel-conversation")
        PanelView.snapshotNav = true
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "5a-panel-conversation-nav")
        PanelView.snapshotNav = false
        await renderTelegram(shell, layout: layout, to: directory)
        shell.tab = .music
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "6-panel-music")
        await renderSpotify(shell, layout: layout, to: directory)
        await renderClipboard(shell, layout: layout, to: directory)
        await renderSourceTabs(shell, layout: layout, to: directory)
        await renderMemoryAndRoutines(shell, layout: layout, to: directory)
        await renderMyMac(shell, layout: layout, to: directory)
        print("snapshot: media player=\(shell.media.player?.name ?? "nil") running=\(shell.media.runningPlayer?.name ?? "nil") denied=\(shell.media.deniedPlayer?.name ?? "nil")")
    }

    private static let margin: CGFloat = 24

    private static func renderSpotify(
        _ shell: ShellController,
        layout: (rest: CGRect, active: CGRect, panel: CGRect, notch: CGRect?),
        to directory: URL
    ) async {
        let spotify = SpotifyModel.shared
        spotify.bootstrap()
        for _ in 0..<30 where spotify.auth == .unknown { try? await Task.sleep(for: .milliseconds(100)) }
        print("snapshot: spotify auth=\(spotify.auth) clientID=\(spotify.hasClientID ? "set" : "empty")")
        guard spotify.auth != .signedIn else { return }
        shell.setSnapshotState(.panel, notch: layout.notch)
        MusicTab.snapshotShowsSteps = true
        shell.tab = .home
        shell.tab = .music
        await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "6b-panel-music-spotify-steps")
        MusicTab.snapshotShowsSteps = false
        let card = SpotifySettingsCard().frame(width: 628).padding(Theme.Layout.panelPadding).background(Theme.bg)
        let host = NSHostingView(rootView: card)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(600))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("6c-settings-spotify-card.png"))
        }
        window.orderOut(nil)
    }

    private static func renderTelegram(
        _ shell: ShellController,
        layout: (rest: CGRect, active: CGRect, panel: CGRect, notch: CGRect?),
        to directory: URL
    ) async {
        let model = shell.conversation
        let telegram = model.telegram
        await model.refreshTelegram()
        print("snapshot: telegram link=\(telegram.link) topics=\(telegram.loadedTopics?.count ?? -1) wisp=\(model.sections.wisp.count) linked=\(model.sections.telegram.filter { $0.record != nil }.count)")
        shell.setSnapshotState(.panel, notch: layout.notch)
        shell.tab = .conversation
        await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "5b-panel-conversation-telegram")
        guard ProcessInfo.processInfo.arguments.contains("-WispTelegramE2E") else { return }
        guard telegram.canSend else {
            print("snapshot: telegram e2e skipped: bot not up (\(telegram.link))")
            return
        }
        func seconds(_ since: ContinuousClock.Instant) -> String {
            let elapsed = since.duration(to: .now).components
            return String(format: "%.1fs", Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        }
        func wait(_ limit: Duration, until done: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + limit
            while !done() {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return true
        }

        let start = ContinuousClock.now
        let reader = telegram.claimFrom
        model.newConversation()
        model.send("responda só: ok")
        if let reader {
            let claiming = ConversationState.Phase.thinking(step: "Trazendo a conversa do \(reader)…")
            let shown = await wait(.seconds(5)) { model.state.phase == claiming }
            let handed = await wait(.seconds(80)) { model.state.phase != claiming }
            print("snapshot: telegram e2e claim from \(reader) shown=\(shown) done=\(handed) in \(seconds(start)) link=\(telegram.link) phase=\(model.state.phase)")
        }
        guard await wait(.seconds(60), until: { model.linkedThread != nil || model.isFailed }), let thread = model.linkedThread else {
            print("snapshot: telegram e2e create failed phase=\(model.state.phase)")
            return
        }
        print("snapshot: telegram e2e created thread \(thread) in \(seconds(start))")
        let sent = start
        let sending = ConversationState.Phase.thinking(step: "Enviando ao Telegram…")
        _ = await wait(.seconds(10)) { model.state.phase == sending }
        let delivered = await wait(.seconds(40)) { model.state.phase != sending }
        print("snapshot: telegram e2e send returned=\(delivered) in \(seconds(sent)) phase=\(model.state.phase)")
        let replied = await wait(.seconds(600)) { !model.isThinking }
        let reply = model.state.messages.last { $0.role == .assistant }?.text ?? "nil"
        print("snapshot: telegram e2e reply=\(replied) in \(seconds(sent)) phase=\(model.state.phase) messages=\(model.state.messages.map { "\($0.role)" }) text=\(reply.prefix(80))")
        await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "5c-panel-conversation-telegram-reply")

        await model.refreshTelegram()
        guard let entry = model.sections.telegram.first(where: { $0.topic.thread == thread }) else {
            print("snapshot: telegram e2e topic \(thread) missing from list; close it by hand")
            return
        }
        let closing = ContinuousClock.now
        model.close(entry)
        _ = await wait(.seconds(1)) { telegram.closing.contains(thread) }
        let closed = await wait(.seconds(310)) { !telegram.closing.contains(thread) }
        let gone = telegram.loadedTopics.map { !$0.contains { $0.thread == thread } } ?? false
        print("snapshot: telegram e2e close returned=\(closed) gone=\(gone) in \(seconds(closing)) error=\(telegram.actionError ?? "nil") linked=\(model.linkedThread.map(String.init) ?? "nil")")
        for record in model.records where record.telegramThread == thread { model.delete(record) }
        print("snapshot: telegram e2e total \(seconds(start)); index records for the thread left=\(model.records.filter { $0.telegramThread == thread }.count)")
    }

    private static func renderMemoryAndRoutines(
        _ shell: ShellController,
        layout: (rest: CGRect, active: CGRect, panel: CGRect, notch: CGRect?),
        to directory: URL
    ) async {
        let profile = shell.conversation.profile
        shell.setSnapshotState(.panel, notch: layout.notch)
        if let memory = profile.blocks?.memory, PanelTab.memory.isAvailable(in: profile), let root = memory.root {
            let model = MemoryModel.shared
            model.refreshRecents(root: root)
            for _ in 0..<50 where model.recents == .loading { try? await Task.sleep(for: .milliseconds(100)) }
            shell.tab = .memory
            await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "b-memory")
            let query = "brain-sync"
            let started = Date()
            await model.search(query, block: memory)
            if case .loaded(_, let hits) = model.search {
                print("snapshot: memory recents=\(model.recents) search \"\(query)\" hits=\(hits.count) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            } else {
                print("snapshot: memory search \(model.search)")
            }
            MemoryTab.snapshotQuery = query
            shell.tab = .home
            shell.tab = .memory
            await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "b-memory-search")
            MemoryTab.snapshotQuery = ""
        }
        if let routines = profile.blocks?.routines, PanelTab.routines.isAvailable(in: profile) {
            let model = RoutinesModel.shared
            model.refresh(block: routines)
            for _ in 0..<50 where model.state == .loading { try? await Task.sleep(for: .milliseconds(100)) }
            if case .loaded(let rows) = model.state {
                for row in rows { print("snapshot: routine \(row.job.label) \(row.summary) logs=\(row.job.logs)") }
            } else {
                print("snapshot: routines \(model.state)")
            }
            shell.tab = .routines
            await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "b-routines")
            RoutinesTab.snapshotLogLabel = "com.owner.meeting-sync"
            shell.tab = .home
            shell.tab = .routines
            await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "b-routines-log")
            RoutinesTab.snapshotLogLabel = nil
        }
    }

    private static func renderSourceTabs(
        _ shell: ShellController,
        layout: (rest: CGRect, active: CGRect, panel: CGRect, notch: CGRect?),
        to directory: URL
    ) async {
        let sources = TabSources.shared
        let profile = shell.conversation.profile
        sources.refresh(profile: profile)
        for _ in 0..<80 where sources.tasks.state == .loading || sources.agenda.state == .loading || sources.alerts.state == .loading {
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("snapshot: tabs nav=\(PanelTab.nav(for: profile).map(\.rawValue)) tasks=\(sources.tasks.openCount ?? -1) alerts=\(sources.alertCount ?? -1) agenda=\(sources.agenda.state)")
        shell.setSnapshotState(.panel, notch: layout.notch)
        for tab in [PanelTab.tasks, .reminders, .agenda] where tab.isAvailable(in: profile) {
            shell.tab = tab
            await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "t-\(tab.rawValue)")
        }
    }

    private static func renderClipboard(
        _ shell: ShellController,
        layout: (rest: CGRect, active: CGRect, panel: CGRect, notch: CGRect?),
        to directory: URL
    ) async {
        let notch = layout.notch
        shell.clipboard.captureForSnapshot()

        shell.setSnapshotState(.panel, notch: notch)
        shell.tab = .clipboard
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "c4-panel-clipboard")
        shell.tab = .settings
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "c5-panel-settings")
        print("snapshot: clipboard items=\(shell.clipboard.history.items.count)")
    }

    private static func renderMyMac(
        _ shell: ShellController,
        layout: (rest: CGRect, active: CGRect, panel: CGRect, notch: CGRect?),
        to directory: URL
    ) async {
        func cpuSeconds() -> Double {
            var own = rusage(), children = rusage()
            getrusage(RUSAGE_SELF, &own)
            getrusage(RUSAGE_CHILDREN, &children)
            func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
            return seconds(own.ru_utime) + seconds(own.ru_stime) + seconds(children.ru_utime) + seconds(children.ru_stime)
        }
        func measure(_ label: String, _ body: () async -> Void) async {
            let cpu = cpuSeconds(), wall = Date()
            await body()
            let used = cpuSeconds() - cpu, elapsed = Date().timeIntervalSince(wall)
            print("snapshot: mymac cpu \(label) \(String(format: "%.3f", used))s over \(String(format: "%.1f", elapsed))s = \(String(format: "%.2f", used / elapsed * 100))% of one core")
        }
        shell.setSnapshotState(.panel, notch: layout.notch)
        shell.tab = .home
        await measure("hidden-before") { try? await Task.sleep(for: .seconds(10)) }
        shell.tab = .myMac
        await measure("visible") {
            await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "m-mymac", settle: .seconds(10))
        }
        shell.tab = .home
        await measure("hidden-after") { try? await Task.sleep(for: .seconds(10)) }
    }

    static func render(_ shell: ShellController, frame: CGRect, notch: CGRect?, to directory: URL, name: String, settle: Duration = .milliseconds(900)) async {
        let root = ZStack(alignment: .topLeading) {
            Color(white: 0.32)
            PillView(controller: shell)
                .frame(width: frame.width, height: frame.height)
                .offset(x: margin)
            if let notch, shell.state != .rest {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height)
                    .offset(x: margin + notch.minX - frame.minX)
            }
        }
        let size = CGSize(width: frame.width + 2 * margin, height: frame.height + margin)
        let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: settle)
        host.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("snapshot: \(url.path)")
        } catch {
            print("snapshot: failed \(name): \(error.localizedDescription)")
        }
    }
}
#endif
