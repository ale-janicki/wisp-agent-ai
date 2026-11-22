#if DEBUG
import AppKit
import SwiftUI
import WispCore

extension SnapshotRenderer {
    static func renderMemoryGraph(
        _ shell: ShellController,
        layout: (rest: CGRect, active: CGRect, panel: CGRect, notch: CGRect?),
        to directory: URL
    ) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let profile = shell.conversation.profile
        guard PanelTab.brain.isAvailable(in: profile), let root = profile.blocks?.memory?.root else {
            print("snapshot: graph skipped, no memory root")
            return
        }
        let model = MemoryGraphModel.shared
        let memory = MemoryModel.shared
        memory.refreshRecents(root: root)
        BrainModel.shared.showsGraph = true
        shell.setSnapshotState(.panel, notch: layout.notch)
        shell.tab = .brain

        model.load(root: root, force: true)
        guard await waitForGraph(model, limit: .seconds(90)) else {
            print("snapshot: graph not ready \(model.phase)")
            return
        }
        let stats = model.lastScanStats
        print("snapshot: graph scan#1 \(format(model.lastScanSeconds))s layout \(format(model.lastLayoutSeconds))s nodes=\(model.graph.nodes.count) edges=\(model.graph.edges.count) read=\((stats?.read).map(String.init) ?? "indisponível") reused=\((stats?.reused).map(String.init) ?? "indisponível") placeholders=\((stats?.placeholders).map(String.init) ?? "indisponível") unreadable=\((stats?.unreadable).map(String.init) ?? "indisponível")")
        let applied = model.scansApplied
        model.load(root: root, force: true)
        for _ in 0..<300 where model.scansApplied == applied { try? await Task.sleep(for: .milliseconds(20)) }
        _ = await waitForGraph(model, limit: .seconds(30))
        print("snapshot: graph scan#2 \(format(model.lastScanSeconds))s read=\((model.lastScanStats?.read).map(String.init) ?? "indisponível") reused=\((model.lastScanStats?.reused).map(String.init) ?? "indisponível") settling=\(model.settling)")

        model.finishAnimationsForSnapshot()
        await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "g1-graph-full")
        await measurePan(shell, frame: layout.panel, label: "full")

        if let hub = model.scene.nodes.indices.max(by: { model.radius(ofScene: $0) < model.radius(ofScene: $1) }) {
            model.hoverForSnapshot(hub)
            print("snapshot: graph hover \(model.title(ofScene: hub)) neighbours=\(model.scene.adjacency[hub].count)")
            await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "g2-graph-hover")
            model.hoverForSnapshot(nil)
        }

        if let hub = model.nodesBySize().first {
            model.zoom(by: 1.6 / model.zoom, at: model.toView(model.frame.positions[hub]))
            model.finishAnimationsForSnapshot()
            print("snapshot: graph zoomed to \(String(format: "%.2f", model.zoom)) around \(model.title(ofScene: hub))")
            await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "g2b-graph-zoom-labels")
            model.fit()
            model.finishAnimationsForSnapshot()
        }

        MemoryGraphView.snapshotForcesOpen = true
        shell.tab = .home
        shell.tab = .brain
        await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "g2c-graph-forces")
        MemoryGraphView.snapshotForcesOpen = false

        let query = "brain-sync"
        BrainTab.snapshotGraphQuery = query
        shell.tab = .home
        shell.tab = .brain
        model.search(query)
        model.finishAnimationsForSnapshot()
        print("snapshot: graph search \"\(query)\" matches=\(model.matches.count) best=\(model.bestMatch.map(model.title(ofScene:)) ?? "indisponível")")
        await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "g3-graph-search")
        BrainTab.snapshotGraphQuery = ""
        model.search("")

        var recent: String?
        for _ in 0..<50 {
            if case .loaded(let notes) = memory.recents { recent = notes.first?.path; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        shell.tab = .home
        shell.tab = .brain
        model.setLocalMode(true, fallback: recent)
        _ = await waitForGraph(model, limit: .seconds(30))
        for _ in 0..<150 where model.frame.running { try? await Task.sleep(for: .milliseconds(100)) }
        model.finishAnimationsForSnapshot()
        print("snapshot: graph local around \(model.selected ?? "indisponível") nodes=\(model.scene.nodes.count) edges=\(model.scene.edges.count)")
        await render(shell, frame: layout.panel, notch: layout.notch, to: directory, name: "g4-graph-local")
        await measurePan(shell, frame: layout.panel, label: "local")
        model.setLocalMode(false, fallback: nil)
    }

    private static func waitForGraph(_ model: MemoryGraphModel, limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if case .failed = model.phase { return false }
            if model.phase == .ready && !model.settling { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func measurePan(_ shell: ShellController, frame: CGRect, label: String) async {
        let model = MemoryGraphModel.shared
        let size = frame.size
        let host = NSHostingView(rootView: PillView(controller: shell).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        let start = model.offset

        GraphDrawStats.seconds = []
        var frames: [Double] = []
        let cpu = cpuSeconds(), wall = CACurrentMediaTime()
        for f in 0..<30 {
            model.pan(by: CGSize(width: f % 60 < 30 ? 6 : -6, height: f % 40 < 20 ? 3 : -3))
            let t = CACurrentMediaTime()
            host.cacheDisplay(in: host.bounds, to: rep)
            frames.append(CACurrentMediaTime() - t)
            if CACurrentMediaTime() - wall > 20 { break }
        }
        let usedCPU = cpuSeconds() - cpu, elapsed = CACurrentMediaTime() - wall
        let draws = GraphDrawStats.seconds
        print("snapshot: graph pan[\(label)] sync frames=\(frames.count) draws=\(draws.count) frame p50=\(ms(frames, 0.5)) p95=\(ms(frames, 0.95)) max=\(ms(frames, 1)) | draw p50=\(ms(draws, 0.5)) p95=\(ms(draws, 0.95)) max=\(ms(draws, 1)) | cpu \(String(format: "%.0f", usedCPU / elapsed * 100))%")

        window.orderOut(nil)
        model.offset = start
    }

    private static func cpuSeconds() -> Double {
        var own = rusage()
        getrusage(RUSAGE_SELF, &own)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(own.ru_utime) + seconds(own.ru_stime)
    }

    private static func ms(_ values: [Double], _ quantile: Double) -> String {
        guard !values.isEmpty else { return "-" }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * quantile))
        return String(format: "%.2fms", sorted[index] * 1000)
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "cached"
    }
}
#endif
