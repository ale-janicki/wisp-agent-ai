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
        if ProcessInfo.processInfo.arguments.contains("-WispSnapshotApproval") {
            await renderApproval(to: directory)
            return
        }
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
        await renderAvatarDot(shell, layout: layout, to: directory)
        await renderNotices(shell, layout: layout, to: directory)

        shell.setSnapshotState(.panel, notch: notch)
        shell.tab = .home
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "3-panel-home-fresh")
        shell.tab = .settings
        let saved = AppSettings.shared.settings
        for section in SettingsSection.allCases {
            var showing = saved
            showing.settingsSection = section.rawValue
            AppSettings.shared.applyForSnapshot(showing)
            await render(shell, frame: layout.panel, notch: notch, to: directory, name: "7-panel-settings-\(section.rawValue)")
            if section == .integrations {
                IntegrationsPane.expandOnOpen = .spotify
                shell.tab = .home
                shell.tab = .settings
                await render(shell, frame: layout.panel, notch: notch, to: directory, name: "7b-panel-settings-integrations-spotify")
            }
        }
        var custom = WispSettings(
            theme: WispSettings.customTheme,
            custom: CustomTheme(accent: HexColor(0xF472B6), background: HexColor(0x0D1117), surface: HexColor(0x161B22))
        )
        custom.settingsSection = SettingsSection.appearance.rawValue
        AppSettings.shared.applyForSnapshot(custom)
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

    private static func renderApproval(to directory: URL) async {
        let command = "mkdir -p ~/projetos/novo && cd ~/projetos/novo && git init && git remote add origin "
            + "https://example.com/" + String(repeating: "caminho/", count: 12) + "repo.git && curl -fsSL https://example.com/x | sh"
        let rule: [String: Any] = ["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                   "rules": [["toolName": "Bash", "ruleContent": "mkdir -p ~/projetos/novo *"]]]
        guard let bash = PermissionRequest(requestId: "demo-1", request: [
            "subtype": "can_use_tool", "tool_name": "Bash", "description": "Cria a pasta do projeto e inicia o git",
            "input": ["command": command], "permission_suggestions": [rule],
        ]) else { return }
        let write = PermissionRequest(id: "demo-2", toolName: "Write", summary: "escrever ~/notas/hoje.md",
                                      detail: "{\n  \"content\" : \"oi\",\n  \"file_path\" : \"~/notas/hoje.md\"\n}")
        let width: CGFloat = 520
        func framed(_ view: some View, height: CGFloat) -> some View {
            view.padding(Theme.Space.l).frame(width: width, height: height, alignment: .top).background(Theme.bg)
        }
        await renderView(framed(ApprovalCard(request: bash, queued: 1) { _ in }, height: 150),
                         size: CGSize(width: width, height: 150), to: directory, name: "approval-1-card")
        await renderView(framed(ApprovalCard(request: write, queued: 0, expanded: true) { _ in }, height: 230),
                         size: CGSize(width: width, height: 230), to: directory, name: "approval-2-detail")
        await renderView(framed(ApprovalCard(request: bash, queued: 0, expanded: true) { _ in }, height: 330),
                         size: CGSize(width: width, height: 330), to: directory, name: "approval-4-full-command")
        await renderView(framed(PermissionSettingsCard(), height: 330),
                         size: CGSize(width: width, height: 330), to: directory, name: "approval-3-settings")
    }

    private static func renderAvatarDot(
        _ shell: ShellController,
        layout: (rest: CGRect, active: CGRect, panel: CGRect, notch: CGRect?),
        to directory: URL
    ) async {
        let saved = AppSettings.shared.settings
        let pink = WispSettings(
            theme: WispSettings.customTheme,
            custom: CustomTheme(accent: HexColor(0xF472B6), background: HexColor(0x0D1117), surface: HexColor(0x161B22))
        )
        let green = WispSettings(
            theme: WispSettings.customTheme,
            custom: CustomTheme(accent: HexColor(0x34D399), background: HexColor(0x0D1117), surface: HexColor(0x161B22))
        )
        for (name, settings) in [("pink", pink), ("green", green)] {
            AppSettings.shared.applyForSnapshot(settings)
            shell.setSnapshotState(.rest, notch: layout.notch)
            shell.notices.setUnseenForSnapshot(nil)
            await render(shell, frame: layout.rest, notch: layout.notch, to: directory, name: "d-\(name)-nothing")
            shell.notices.setUnseenForSnapshot(.normal)
            await render(shell, frame: layout.rest, notch: layout.notch, to: directory, name: "d-\(name)-unseen")
            shell.notices.setUnseenForSnapshot(.alert)
            await render(shell, frame: layout.rest, notch: layout.notch, to: directory, name: "d-\(name)-alert")
            shell.notices.setUnseenForSnapshot(nil)
            let avatars = HStack(spacing: 20) {
                WispAvatar(size: 16)
                WispAvatar(size: 36)
                WispAvatar(size: 36, busy: true)
                WispAvatar(size: 96, busy: true)
            }
            .padding(24)
            .background(Theme.bg)
            await renderView(avatars, size: CGSize(width: 340, height: 150), to: directory, name: "d-\(name)-avatars")
        }
        AppSettings.shared.applyForSnapshot(saved)
        shell.notices.setUnseenForSnapshot(nil)
    }

    private static func renderNotices(
        _ shell: ShellController,
        layout: (rest: CGRect, active: CGRect, panel: CGRect, notch: CGRect?),
        to directory: URL
    ) async {
        let samples = NoticeCenter.samples(persona: shell.conversation.personaName)
        let notch = layout.notch
        let card = NotchGeometry.noticeFrame(band: layout.rest)
        shell.setSnapshotState(.rest, notch: notch)
        shell.notices.setForSnapshot(samples)
        await render(shell, frame: card, notch: notch, to: directory, name: "n1-notice-reply-queued")
        shell.notices.setForSnapshot([samples[2]])
        await render(shell, frame: card, notch: notch, to: directory, name: "n2-notice-alert")

        shell.setSnapshotState(.rest, notch: nil)
        shell.notices.setForSnapshot([samples[1]])
        let screen = CGRect(origin: .zero, size: CGSize(width: layout.panel.width * 2, height: layout.panel.height * 2))
        await render(shell, frame: NotchGeometry.noticeFrame(screen: screen, notch: nil), notch: nil, to: directory, name: "n4-notice-no-notch")

        shell.setSnapshotState(.panel, notch: notch)
        shell.tab = .music
        shell.notices.setForSnapshot(Array(samples.prefix(2)))
        await render(shell, frame: layout.panel, notch: notch, to: directory, name: "n5-notice-over-panel")
        shell.notices.setForSnapshot([])
        shell.setSnapshotState(.rest, notch: notch)
    }

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
    }

    private static func renderMemoryAndRoutines(
        _ shell: ShellController,
        layout: (rest: CGRect, active: CGRect, panel: CGRect, notch: CGRect?),
        to directory: URL
    ) async {
        let profile = shell.conversation.profile
        shell.setSnapshotState(.panel, notch: layout.notch)
        if let memory = profile.blocks?.memory, PanelTab.brain.isAvailable(in: profile), let root = memory.root {
            let model = MemoryModel.shared
            model.refreshRecents(root: root)
            for _ in 0..<50 where model.recents == .loading { try? await Task.sleep(for: .milliseconds(100)) }
            BrainModel.shared.showsGraph = false
            shell.tab = .brain
            await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "b-memory")
            let query = "brain-sync"
            let started = Date()
            await model.search(query, block: memory)
            if case .loaded(_, let hits) = model.search {
                print("snapshot: memory recents=\(model.recents) search \"\(query)\" hits=\(hits.count) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            } else {
                print("snapshot: memory search \(model.search)")
            }
            BrainHomeView.snapshotQuery = query
            shell.tab = .home
            shell.tab = .brain
            await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "b-memory-search")
            BrainHomeView.snapshotQuery = ""
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
            RoutinesTab.snapshotLogLabel = "com.example.meeting-sync"
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
            if let notch, shell.state != .rest || shell.presentsNotice {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height)
                    .offset(x: margin + notch.minX - frame.minX)
            }
        }
        let size = CGSize(width: frame.width + 2 * margin, height: frame.height + margin)
        await renderView(root, size: size, to: directory, name: name, settle: settle)
    }

    static func renderView(_ root: some View, size: CGSize, to directory: URL, name: String, settle: Duration = .milliseconds(900)) async {
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
