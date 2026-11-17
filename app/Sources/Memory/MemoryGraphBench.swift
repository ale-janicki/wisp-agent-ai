#if DEBUG
import AppKit
import os
import QuartzCore
import WispCore

@MainActor
enum MemoryGraphBench {
    private static let log = GraphFramePerf.log
    private static let inputInterval: Duration = .milliseconds(8)
    private static weak var shell: ShellController?

    static func run(_ shell: ShellController) async {
        log.notice("bench: start")
        let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "graph bench")
        defer {
            ProcessInfo.processInfo.endActivity(awake)
            NSApp.terminate(nil)
        }
        guard let root = shell.conversation.profile.blocks?.memory?.root else {
            log.notice("bench: no memory root in the profile")
            return
        }
        let model = MemoryGraphModel.shared
        Self.shell = shell
        MemoryTab.lastMode = .graph
        shell.tab = .memory
        shell.show(.panel)
        model.load(root: root)
        guard await wait(limit: .seconds(120), until: { model.phase == .ready && !model.settling }) else {
            log.notice("bench: graph not ready \(String(describing: model.phase), privacy: .public)")
            return
        }
        _ = await wait(limit: .seconds(20)) { !model.frame.running }
        try? await Task.sleep(for: .seconds(1))
        log.notice("bench: full graph nodes=\(model.scene.nodes.count) edges=\(model.scene.edges.count)")
        guard onScreen("full", model), await phases("full", model), await idleCPU("full", model) else { return }

        let recent = MemoryModel.shared.recents.firstPath
        let hub = model.nodesBySize().first.map { model.graph.nodes[model.scene.nodes[$0]].id }
        model.setLocalMode(true, fallback: recent ?? hub)
        _ = await wait(limit: .seconds(20)) { !model.frame.running }
        model.fit()
        try? await Task.sleep(for: .seconds(1))
        log.notice("bench: local graph around \(model.selected ?? "nil", privacy: .public) nodes=\(model.scene.nodes.count) edges=\(model.scene.edges.count)")
        guard onScreen("local", model), await phases("local", model), await idleCPU("local", model) else { return }
        model.setLocalMode(false, fallback: nil)
        guard await abandonedDrag(shell, model) else { return }
        log.notice("bench: done")
    }

    private static func abandonedDrag(_ shell: ShellController, _ model: MemoryGraphModel) async -> Bool {
        model.fit()
        _ = await wait(limit: .seconds(10)) { !model.frame.running && !model.isAnimating }
        guard let hub = model.nodesBySize().first, model.frame.positions.indices.contains(hub) else { return false }
        guard onScreen("abandoned drag", model) else { return false }
        model.beginDrag(hub, at: model.toView(model.frame.positions[hub]))
        for step in 0..<30 {
            model.drag(to: CGPoint(x: model.toView(model.frame.positions[hub]).x + CGFloat(step), y: model.toView(model.frame.positions[hub]).y))
            try? await Task.sleep(for: inputInterval)
        }
        guard onScreen("abandoned drag close", model) else {
            model.cancelDrag()
            return false
        }
        log.notice("bench abandoned drag: before close dragging=\(model.dragging != nil) simRunning=\(model.frame.running)")
        shell.show(.rest)
        let cpu = cpuSeconds()
        let start = CACurrentMediaTime()
        try? await Task.sleep(for: .seconds(3))
        let percent = (cpuSeconds() - cpu) / (CACurrentMediaTime() - start) * 100
        log.notice("bench abandoned drag: 3 s after close dragging=\(model.dragging != nil) simRunning=\(model.frame.running) animating=\(model.isAnimating) cpu=\(percent, format: .fixed(precision: 2))% of one core")
        shell.show(.panel)
        return true
    }

    private static func onScreen(_ step: String, _ model: MemoryGraphModel) -> Bool {
        let state = shell.map { String(describing: $0.state) } ?? "nil"
        let tab = shell.map { $0.tab.rawValue } ?? "nil"
        let visible = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        guard shell?.state == .panel, shell?.tab == .memory, model.displayOwner != nil, visible else {
            log.notice("bench: aborted at \(step, privacy: .public): graph not on screen (state=\(state, privacy: .public) tab=\(tab, privacy: .public) view=\(model.displayOwner != nil) visible=\(visible)); panel used, display asleep or screen locked during the run?")
            return false
        }
        return true
    }

    private static func phases(_ label: String, _ model: MemoryGraphModel) async -> Bool {
        guard await measure("\(label) drag", seconds: 5, model, input: { t in
            guard let hub = model.nodesBySize().first else { return }
            let positions = model.frame.positions
            guard positions.indices.contains(hub) else { return }
            if model.dragging == nil {
                let point = model.toView(positions[hub])
                model.beginDrag(hub, at: point)
                anchor = point
            }
            let angle = t * 2 * .pi / 2.5
            model.drag(to: CGPoint(x: anchor.x + 90 * cos(angle) - 90, y: anchor.y + 60 * sin(angle)))
        }, finish: {
            model.endDrag(at: nil)
        }) else { return false }
        _ = await wait(limit: .seconds(15)) { !model.frame.running }
        model.fit()
        _ = await wait(limit: .seconds(5)) { !model.isAnimating }

        guard await measure("\(label) pan", seconds: 3, model, input: { t in
            let speed: CGFloat = 400
            let dx = (t.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : -1) * speed * 0.008
            model.pan(by: CGSize(width: dx, height: dx * 0.4))
        }, finish: {
            model.endPan()
        }) else { return false }
        _ = await wait(limit: .seconds(5)) { !model.isAnimating }

        guard await measure("\(label) zoom", seconds: 3, model, input: { t in
            let direction: CGFloat = t.truncatingRemainder(dividingBy: 1.5) < 0.75 ? 1 : -1
            model.zoomSmoothly(by: exp(direction * 0.03), at: nil)
        }, finish: {}) else { return false }
        model.fit()
        _ = await wait(limit: .seconds(5)) { !model.isAnimating }
        return true
    }

    private static var anchor: CGPoint = .zero

    private static func measure(_ label: String, seconds: Double, _ model: MemoryGraphModel, input: (Double) -> Void, finish: () -> Void) async -> Bool {
        guard onScreen(label, model) else { return false }
        GraphDrawStats.probe = []
        let cpu = cpuSeconds()
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < seconds {
            input(CACurrentMediaTime() - start)
            try? await Task.sleep(for: inputInterval)
        }
        let elapsed = CACurrentMediaTime() - start
        let used = cpuSeconds() - cpu
        let probe = GraphDrawStats.probe ?? []
        GraphDrawStats.probe = nil
        finish()
        guard onScreen("end of \(label)", model) else { return false }
        let summary = GraphFramePerf.summary(stamps: probe.map(\.time), drawMillis: probe.map(\.millis))
        log.notice("bench \(label, privacy: .public): \(summary, privacy: .public) cpu=\(Int(used / elapsed * 100))% of one core")
        return true
    }

    private static func idleCPU(_ label: String, _ model: MemoryGraphModel) async -> Bool {
        let rested = await wait(limit: .seconds(20)) { !model.frame.running && !model.isAnimating }
        try? await Task.sleep(for: .seconds(1))
        GraphDrawStats.probe = []
        let cpu = cpuSeconds()
        let start = CACurrentMediaTime()
        try? await Task.sleep(for: .seconds(5))
        let used = cpuSeconds() - cpu
        let draws = GraphDrawStats.probe?.count ?? 0
        GraphDrawStats.probe = nil
        let percent = used / (CACurrentMediaTime() - start) * 100
        guard onScreen("\(label) idle", model) else { return false }
        log.notice("bench \(label, privacy: .public) idle: rested=\(rested) cpu=\(percent, format: .fixed(precision: 2))% of one core over 5 s, canvas draws=\(draws)")
        return true
    }

    private static func wait(limit: Duration, until done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    private static func cpuSeconds() -> Double {
        var own = rusage()
        getrusage(RUSAGE_SELF, &own)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(own.ru_utime) + seconds(own.ru_stime)
    }
}

private extension MemoryModel.Recents {
    var firstPath: String? {
        if case .loaded(let notes) = self { return notes.first?.path }
        return nil
    }
}
#endif
