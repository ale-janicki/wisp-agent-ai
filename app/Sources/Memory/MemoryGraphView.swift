import AppKit
import os
import QuartzCore
import SwiftUI
import WispCore

struct MemoryGraphView: View {
    let root: String
    let query: String
    let recent: String?
    let open: (String) -> Void
    private let model = MemoryGraphModel.shared
    @State private var forcesOpen = Self.initialForcesOpen

    #if DEBUG
    static var snapshotForcesOpen = false
    #endif

    private static var initialForcesOpen: Bool {
        #if DEBUG
        return snapshotForcesOpen
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .scanning:
                scanning
            case .failed(let message):
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    InlineError(text: message)
                    Spacer(minLength: 0)
                }
            case .ready where model.graph.nodes.isEmpty:
                TabMessage(text: "Nenhuma nota nesta pasta")
            case .ready:
                graph
            }
        }
        .onAppear { model.load(root: root) }
        .onDisappear { model.cancelDrag() }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            model.search(query)
        }
    }

    private var scanning: some View {
        ZStack(alignment: .bottomLeading) {
            Skeleton(cornerRadius: Theme.Radius.nav)
            Text(scanningCaption)
                .font(Theme.Font.captionMono)
                .foregroundStyle(Theme.textTertiary)
                .padding(Theme.Space.m)
        }
    }

    private var scanningCaption: String {
        if case .scanning(let count) = model.phase, count > 0 { return "Lendo notas… \(count)" }
        return "Lendo notas…"
    }

    private var graph: some View {
        ZStack {
            GraphCanvas(model: model)
                .allowsHitTesting(false)
            GraphInput(model: model, open: open)
                .zIndex(-1)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    caption
                    Spacer(minLength: Theme.Space.s)
                    Button { forcesOpen.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(CircleButtonStyle(kind: forcesOpen ? .accent : .plain, size: Theme.Control.compactHeight))
                        .help(forcesOpen ? "Fechar ajustes do grafo" : "Forças e exibição")
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    GraphLegend(folders: model.folders, ghosts: model.showGhosts)
                    Spacer(minLength: Theme.Space.s)
                    controls
                }
            }
            .padding(Theme.Space.s)
            if forcesOpen {
                GraphForcesPanel(model: model)
                    .padding(.top, 28 + 2 * Theme.Space.s)
                    .padding([.trailing, .bottom], Theme.Space.s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: forcesOpen)
        .background(Theme.Graph.well, in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
    }

    private var caption: some View {
        Text(captionText)
            .font(Theme.Font.captionMono)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.top, 6)
    }

    private var captionText: String {
        var parts: [String] = []
        if model.localMode, let selected = model.selected {
            parts.append("\(MemoryNote.title(of: selected)) · \(model.scene.nodes.count) notas")
        } else {
            let notes = model.graph.nodes.count { !$0.isGhost }
            parts.append("\(notes.formatted()) notas · \(model.graph.edges.count.formatted()) links")
        }
        if !model.matches.isEmpty { parts.append(model.matches.count == 1 ? "1 encontrada" : "\(model.matches.count) encontradas") }
        if model.placeholders > 0 { parts.append("\(model.placeholders) só no iCloud") }
        if model.settling { parts.append("organizando…") }
        return parts.joined(separator: " · ")
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button { model.setLocalMode(!model.localMode, fallback: recent) } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(CircleButtonStyle(kind: model.localMode ? .accent : .plain, size: Theme.Control.compactHeight))
            .help(model.localMode ? "Mostrar o grafo inteiro" : "Grafo local: a nota e vizinhos até 2 passos")
            Button { model.showGhosts.toggle() } label: { Image(systemName: "circle.dashed") }
                .buttonStyle(CircleButtonStyle(kind: model.showGhosts ? .accent : .plain, size: Theme.Control.compactHeight))
                .help(model.showGhosts ? "Esconder links sem nota" : "Mostrar links sem nota")
            Button { model.zoomSmoothly(by: 1 / 1.4, at: nil) } label: { Image(systemName: "minus") }
                .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                .help("Afastar")
            Button { model.zoomSmoothly(by: 1.4, at: nil) } label: { Image(systemName: "plus") }
                .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                .help("Aproximar")
            Button { model.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                .help("Enquadrar")
        }
    }
}

#if DEBUG
@MainActor enum GraphDrawStats {
    static var seconds: [Double] = []
    static var probe: [(time: Double, millis: Double)]?
}
#endif

#if DEBUG
@MainActor enum GraphFramePerf {
    private static var stamps: [Double] = []
    private static var drawMillis: [Double] = []
    private static var flush: Task<Void, Never>?
    static let log = Logger(subsystem: AppIdentity.bundleID, category: "graphperf")

    static func record(at time: Double, drawSeconds: Double) {
        stamps.append(time)
        drawMillis.append(drawSeconds * 1000)
        if stamps.count > 2_000 {
            stamps.removeFirst(1_000)
            drawMillis.removeFirst(1_000)
        }
        flush?.cancel()
        flush = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            report()
        }
    }

    private static func report() {
        defer {
            stamps.removeAll()
            drawMillis.removeAll()
        }
        guard stamps.count >= 10 else { return }
        let summary = Self.summary(stamps: stamps, drawMillis: drawMillis)
        log.notice("\(summary, privacy: .public)")
    }

    static func summary(stamps: [Double], drawMillis: [Double]) -> String {
        let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }.sorted()
        let draws = drawMillis.sorted()
        func percentile(_ sorted: [Double], _ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        let span = (stamps.last ?? 0) - (stamps.first ?? 0)
        let fps = span > 0 ? Double(stamps.count - 1) / span : 0
        return String(
            format: "frames=%d interval p50=%.1f ms p95=%.1f ms max=%.1f ms (%.0f fps) draw-closure p50=%.1f ms p95=%.1f ms",
            stamps.count, percentile(gaps, 0.5), percentile(gaps, 0.95), gaps.last ?? 0, fps, percentile(draws, 0.5), percentile(draws, 0.95)
        )
    }
}
#endif

private struct GraphCanvas: View {
    let model: MemoryGraphModel

    var body: some View {
        GeometryReader { geo in
            let tick = model.frameTick
            Canvas { context, size in
                _ = tick
                let started = CACurrentMediaTime()
                #if DEBUG
                defer {
                    let finished = CACurrentMediaTime()
                    GraphDrawStats.seconds.append(finished - started)
                    GraphDrawStats.probe?.append((started, (finished - started) * 1000))
                    GraphFramePerf.record(at: started, drawSeconds: finished - started)
                }
                #endif
                model.advance(to: started)
                draw(&context, size: size, now: started)
            }
            .onAppear { model.setViewSize(geo.size) }
            .onChange(of: geo.size) { _, size in model.setViewSize(size) }
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, now: Double) {
        let scene = model.scene
        let frame = model.frame
        let controls = model.controls
        let zoom = model.zoom
        let edgeWidth = max(0.6 / zoom, 0.25) * CGFloat(controls.linkThickness)
        var world = context
        world.translateBy(x: size.width / 2 + model.offset.width, y: size.height / 2 + model.offset.height)
        world.scaleBy(x: zoom, y: zoom)

        let shown = model.fadeProgress(at: now)
        if let fade = model.fade {
            var old = world
            old.opacity = 1 - shown
            for chunk in fade.frame.edgePaths { old.stroke(chunk, with: .color(Theme.Graph.edge), lineWidth: edgeWidth) }
            for (group, path) in fade.frame.nodePaths { old.fill(path, with: .color(color(group))) }
        }
        guard !scene.isEmpty, frame.positions.count == scene.nodes.count else { return }

        let dim = model.dimAmount
        var base = world
        base.opacity = shown * (1 - (1 - MemoryGraphModel.dimmed) * dim)
        for chunk in frame.edgePaths { base.stroke(chunk, with: .color(Theme.Graph.edge), lineWidth: edgeWidth) }
        for (group, path) in model.nodePaths(for: frame, scene: scene) { base.fill(path, with: .color(color(group))) }

        let focus = focusSet(scene)
        var lit = world
        lit.opacity = shown
        highlight(&lit, scene: scene, positions: frame.positions, focus: focus, zoom: zoom, thickness: CGFloat(controls.linkThickness))
        var text = context
        text.opacity = shown
        labels(&text, scene: scene, positions: frame.positions, focus: focus, size: size, fade: controls.textFade)
    }

    private func focusSet(_ scene: GraphScene) -> Set<Int> {
        if let hovered = model.hoverShown, scene.adjacency.indices.contains(hovered) {
            return Set(scene.adjacency[hovered]).union([hovered])
        }
        return model.matches
    }

    private func circle(_ p: SIMD2<Float>, _ r: CGFloat) -> CGRect {
        CGRect(x: CGFloat(p.x) - r, y: CGFloat(p.y) - r, width: 2 * r, height: 2 * r)
    }

    private func highlight(_ world: inout GraphicsContext, scene: GraphScene, positions: [SIMD2<Float>], focus: Set<Int>, zoom: CGFloat, thickness: CGFloat) {
        let hovered = model.hoverShown.flatMap { scene.adjacency.indices.contains($0) ? $0 : nil }
        let amount = hovered != nil ? model.hoverAmount : model.dimAmount
        let floor = GraphSimulator.minimumScreenRadius / zoom
        if !focus.isEmpty, amount > 0 {
            var layer = world
            layer.opacity *= amount
            if let hovered {
                var lines = Path()
                let from = CGPoint(x: CGFloat(positions[hovered].x), y: CGFloat(positions[hovered].y))
                for neighbor in scene.adjacency[hovered] {
                    lines.move(to: from)
                    lines.addLine(to: CGPoint(x: CGFloat(positions[neighbor].x), y: CGFloat(positions[neighbor].y)))
                }
                layer.stroke(lines, with: .color(Theme.accent.opacity(0.7)), lineWidth: max(1.3 / zoom, 0.5) * thickness)
            }
            var groups: [Int: Path] = [:]
            for i in focus where i != hovered {
                groups[model.group(ofScene: i), default: Path()].addEllipse(in: circle(positions[i], max(model.radius(ofScene: i), floor)))
            }
            for (group, path) in groups { layer.fill(path, with: .color(color(group))) }
            if let hovered {
                let grown = max(model.radius(ofScene: hovered), floor) * (1 + 0.3 * amount)
                layer.fill(Path(ellipseIn: circle(positions[hovered], grown)), with: .color(color(model.group(ofScene: hovered))))
            }
        }
        let ring = hovered ?? model.bestMatch ?? model.selectedSceneIndex
        if let ring, positions.indices.contains(ring) {
            var layer = world
            if ring == hovered, model.bestMatch != ring, model.selectedSceneIndex != ring { layer.opacity *= amount }
            let grow: CGFloat = ring == hovered ? 1 + 0.3 * amount : 1
            let r = max(model.radius(ofScene: ring), floor) * grow + 3 / zoom
            layer.stroke(Path(ellipseIn: circle(positions[ring], r)), with: .color(Theme.textPrimary), lineWidth: 1.5 / zoom)
        }
    }

    private func labels(_ context: inout GraphicsContext, scene: GraphScene, positions: [SIMD2<Float>], focus: Set<Int>, size: CGSize, fade: Float) {
        let zoomShown = min(max(Double(log2(model.zoom)) - Double(fade) + 1, 0), 1)
        let hover = model.hoverShown != nil ? model.hoverAmount : 0
        let dim = model.dimAmount
        let limit = 90
        var chosen: [(index: Int, alpha: Double, primary: Bool)] = []
        var taken = Set<Int>()
        func take(_ i: Int, _ alpha: Double, primary: Bool = false) {
            guard alpha > 0.02, chosen.count < limit, !taken.contains(i) else { return }
            taken.insert(i)
            chosen.append((i, alpha, primary))
        }
        if let hovered = model.hoverShown, positions.indices.contains(hovered) { take(hovered, hover, primary: true) }
        if let best = model.bestMatch { take(best, 1, primary: model.hoverShown == nil) }
        if let center = model.selectedSceneIndex { take(center, 1, primary: model.hoverShown == nil && model.bestMatch == nil) }
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -20)
        let order = model.nodesBySize()
        if !focus.isEmpty {
            let amount = model.hoverShown != nil ? hover : dim
            for i in order where focus.contains(i) && chosen.count < limit {
                if viewport.contains(model.toView(positions[i])) { take(i, max(amount, zoomShown)) }
            }
        }
        if zoomShown > 0.02 {
            let rest = zoomShown * (1 - (1 - MemoryGraphModel.dimmed) * dim)
            for i in order where chosen.count < limit {
                if viewport.contains(model.toView(positions[i])) { take(i, rest) }
            }
        }
        var placed: [CGRect] = []
        var drawn: [(text: GraphicsContext.ResolvedText, frame: CGRect, alpha: Double, primary: Bool)] = []
        for label in chosen {
            let p = model.toView(positions[label.index])
            let r = max(model.radius(ofScene: label.index) * model.zoom, GraphSimulator.minimumScreenRadius)
            let text = context.resolve(
                Text(model.title(ofScene: label.index))
                    .font(label.primary ? Theme.Font.bodyMedium : Theme.Font.caption)
                    .foregroundStyle(label.primary ? Theme.textPrimary : Theme.textSecondary)
            )
            let measured = text.measure(in: CGSize(width: 220, height: 40))
            let frame = CGRect(x: p.x - measured.width / 2, y: p.y + r + 3, width: measured.width, height: measured.height)
            let padded = frame.insetBy(dx: -6, dy: -2)
            if placed.contains(where: { $0.intersects(padded) }) { continue }
            placed.append(padded)
            drawn.append((text, frame, label.alpha, label.primary))
        }
        for label in drawn.reversed() {
            var layer = context
            layer.opacity *= label.alpha
            if label.primary {
                let box = label.frame.insetBy(dx: -6, dy: -1)
                layer.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(Theme.surfaceHi.opacity(0.92)))
            }
            layer.draw(label.text, in: label.frame)
        }
    }

    private func color(_ group: Int) -> Color {
        if group < 0 { return Theme.Graph.ghost }
        return group < Theme.Graph.palette.count ? Theme.Graph.palette[group] : Theme.Graph.other
    }
}

private struct GraphForcesPanel: View {
    let model: MemoryGraphModel
    private let settings = AppSettings.shared

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollIndicators(.hidden)
        }
        .frame(width: 290)
        .glass()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption(text: "Forças")
            row("Força central", \.center, GraphControls.ranges.center, reheat: GraphLayout.dragAlpha)
            row("Repulsão", \.repel, GraphControls.ranges.repel, reheat: GraphLayout.dragAlpha)
            row("Força dos links", \.link, GraphControls.ranges.link, reheat: GraphLayout.dragAlpha)
            row("Distância dos links", \.linkDistance, GraphControls.ranges.linkDistance, reheat: GraphLayout.dragAlpha)
            SectionCaption(text: "Exibição")
            row("Tamanho dos nós", \.nodeSize, GraphControls.ranges.nodeSize, reheat: GraphLayout.warmAlpha)
            row("Espessura dos links", \.linkThickness, GraphControls.ranges.linkThickness, reheat: 0)
            row("Limiar do texto", \.textFade, GraphControls.ranges.textFade, reheat: 0)
            Button("Animar") { model.animateLayout() }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                .help("Espalhar as notas e ver o grafo se organizar")
                .frame(maxWidth: .infinity)
        }
        .padding(Theme.Space.m)
    }

    private func row(_ title: String, _ key: WritableKeyPath<GraphControls, Float>, _ range: ClosedRange<Float>, reheat: Float) -> some View {
        let value = Binding<Double>(
            get: { Double(settings.settings.graph[keyPath: key]) },
            set: { next in
                settings.setGraph { $0[keyPath: key] = Float(next) }
                model.controlsChanged(reheat: reheat)
            }
        )
        return HStack(spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
            Slider(value: value, in: Double(range.lowerBound)...Double(range.upperBound))
                .controlSize(.mini)
                .tint(Theme.accent)
            Text(value.wrappedValue, format: .number.precision(.fractionLength(range.upperBound > 20 ? 0 : 1)))
                .font(Theme.Font.captionMono)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 30, alignment: .trailing)
        }
        .frame(height: 22)
    }
}

private struct GraphLegend: View {
    let folders: [String]
    let ghosts: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach([6, 4, 3, 2, 0], id: \.self) { shown in
                chips(shown)
            }
        }
    }

    private func chips(_ shown: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(folders.prefix(shown).enumerated()), id: \.offset) { slot, folder in
                chip(folder, Theme.Graph.palette[slot])
            }
            if shown > 0 && !folders.isEmpty { chip("outros", Theme.Graph.other) }
            if ghosts { chip("sem nota", Theme.Graph.ghost) }
        }
        .fixedSize()
    }

    private func chip(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Theme.surfaceHi.opacity(0.85), in: Capsule())
    }
}

private struct GraphInput: NSViewRepresentable {
    let model: MemoryGraphModel
    let open: (String) -> Void

    func makeNSView(context: Context) -> GraphInputView {
        let view = GraphInputView()
        view.model = model
        view.open = open
        return view
    }

    func updateNSView(_ view: GraphInputView, context: Context) {
        view.model = model
        view.open = open
    }
}

final class GraphInputView: NSView {
    var model: MemoryGraphModel?
    var open: ((String) -> Void)?
    private var downAt: NSPoint?
    private var lastDrag: NSPoint?
    private var pressedNode: Int?
    private var dragging = false
    private var link: CADisplayLink?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else {
            model?.cancelDrag()
            dragging = false
            pressedNode = nil
            downAt = nil
            if model?.displayOwner == ObjectIdentifier(self) {
                model?.wakeDisplay = nil
                model?.displayOwner = nil
            }
            return
        }
        let link = displayLink(target: self, selector: #selector(refresh))
        link.add(to: .main, forMode: .common)
        link.isPaused = !(model?.isAnimating ?? false)
        self.link = link
        model?.displayOwner = ObjectIdentifier(self)
        model?.wakeDisplay = { [weak self] in self?.link?.isPaused = false }
    }

    @objc private func refresh(_ link: CADisplayLink) {
        guard let model, model.isAnimating else {
            link.isPaused = true
            return
        }
        model.displayFrame()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private func local(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        model?.hover(at: local(event))
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        guard !dragging else { return }
        model?.hover(at: nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        downAt = local(event)
        lastDrag = downAt
        dragging = false
        model?.stopMomentum()
        pressedNode = downAt.flatMap { model?.node(at: $0) }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = local(event)
        guard let model, let start = downAt, let last = lastDrag else { return }
        if !dragging {
            guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
            dragging = true
            if let node = pressedNode {
                model.beginDrag(node, at: start)
            } else {
                model.hover(at: nil)
            }
        }
        if pressedNode != nil {
            model.drag(to: point)
        } else {
            model.pan(by: CGSize(width: point.x - last.x, height: point.y - last.y), at: event.timestamp)
        }
        lastDrag = point
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        let point = local(event)
        defer {
            downAt = nil
            lastDrag = nil
            pressedNode = nil
            dragging = false
            updateCursor()
        }
        guard let model else { return }
        if dragging {
            if pressedNode != nil { model.endDrag(at: point) } else { model.endPan(at: event.timestamp) }
            return
        }
        if let path = model.click(at: point) { open?(path) }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
        guard delta != 0 else { return }
        model?.zoomSmoothly(by: exp(delta), at: local(event))
    }

    override func magnify(with event: NSEvent) {
        model?.zoom(by: 1 + event.magnification, at: local(event))
    }

    private func updateCursor() {
        if model?.isHovering == true { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }
}
