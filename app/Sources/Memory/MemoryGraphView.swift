import AppKit
import os
import SwiftUI
import WispCore

struct MemoryGraphView: View {
    let root: String
    let query: String
    let recent: String?
    let open: (String) -> Void
    private let model = MemoryGraphModel.shared

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
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    GraphLegend(folders: model.folders, ghosts: model.showGhosts)
                    Spacer(minLength: Theme.Space.s)
                    controls
                }
            }
            .padding(Theme.Space.s)
        }
        .background(Theme.Graph.well, in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
    }

    private var caption: some View {
        Text(captionText)
            .font(Theme.Font.captionMono)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.xs)
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
            .buttonStyle(CircleButtonStyle(kind: model.localMode ? .accent : .plain, size: 28))
            .help(model.localMode ? "Mostrar o grafo inteiro" : "Grafo local: a nota e vizinhos até 2 passos")
            Button { model.showGhosts.toggle() } label: { Image(systemName: "circle.dashed") }
                .buttonStyle(CircleButtonStyle(kind: model.showGhosts ? .accent : .plain, size: 28))
                .help(model.showGhosts ? "Esconder links sem nota" : "Mostrar links sem nota")
            Button { model.zoom(by: 1 / 1.4, at: nil) } label: { Image(systemName: "minus") }
                .buttonStyle(CircleButtonStyle(size: 28))
                .help("Afastar")
            Button { model.zoom(by: 1.4, at: nil) } label: { Image(systemName: "plus") }
                .buttonStyle(CircleButtonStyle(size: 28))
                .help("Aproximar")
            Button { model.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(CircleButtonStyle(size: 28))
                .help("Enquadrar")
        }
    }
}

#if DEBUG
@MainActor enum GraphDrawStats {
    static var seconds: [Double] = []
}
#endif

#if DEBUG
@MainActor enum GraphFramePerf {
    private static var stamps: [Double] = []
    private static var drawMillis: [Double] = []
    private static var flush: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.owner.wisp", category: "graphperf")

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
        let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }.sorted()
        let draws = drawMillis.sorted()
        func percentile(_ sorted: [Double], _ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        log.info("""
        frames=\(stamps.count) interval p50=\(percentile(gaps, 0.5), format: .fixed(precision: 1)) ms \
        p95=\(percentile(gaps, 0.95), format: .fixed(precision: 1)) ms max=\(gaps.last ?? 0, format: .fixed(precision: 1)) ms \
        draw-closure p50=\(percentile(draws, 0.5), format: .fixed(precision: 1)) ms p95=\(percentile(draws, 0.95), format: .fixed(precision: 1)) ms
        """)
    }
}
#endif

private struct GraphCanvas: View {
    let model: MemoryGraphModel

    var body: some View {
        GeometryReader { geo in
            let key = [model.scene.version, model.hovered ?? -1, model.bestMatch ?? -1, model.matches.count, model.localMode ? 1 : 0, model.edgePathsVersion]
            let viewport = [model.zoom, model.offset.width, model.offset.height]
            Canvas { context, size in
                _ = (key, viewport)
                #if DEBUG
                let started = CACurrentMediaTime()
                defer {
                    let finished = CACurrentMediaTime()
                    GraphDrawStats.seconds.append(finished - started)
                    GraphFramePerf.record(at: started, drawSeconds: finished - started)
                }
                #endif
                draw(&context, size: size)
            }
            .onAppear { model.setViewSize(geo.size) }
            .onChange(of: geo.size) { _, size in model.setViewSize(size) }
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let scene = model.scene
        guard !scene.isEmpty else { return }
        let zoom = model.zoom
        let paths = model.paths
        paths.update(model)

        let focus = focusSet(scene)
        var world = context
        world.translateBy(x: size.width / 2 + model.offset.width, y: size.height / 2 + model.offset.height)
        world.scaleBy(x: zoom, y: zoom)

        var base = world
        if !focus.isEmpty { base.opacity = 0.16 }
        let edgeWidth = max(0.6 / zoom, 0.25)
        for chunk in model.edgePaths {
            base.stroke(chunk, with: .color(Theme.Graph.edge), lineWidth: edgeWidth)
        }
        for (group, path) in paths.nodes {
            base.fill(path, with: .color(color(group)))
        }

        if !focus.isEmpty || model.selectedSceneIndex != nil {
            highlight(&world, scene: scene, focus: focus, zoom: zoom)
        }
        labels(&context, scene: scene, focus: focus, size: size)
    }

    private func focusSet(_ scene: GraphScene) -> Set<Int> {
        if let hovered = model.hovered, scene.adjacency.indices.contains(hovered) {
            return Set(scene.adjacency[hovered]).union([hovered])
        }
        return model.matches
    }

    private func highlight(_ world: inout GraphicsContext, scene: GraphScene, focus: Set<Int>, zoom: CGFloat) {
        if let hovered = model.hovered, scene.adjacency.indices.contains(hovered) {
            var lines = Path()
            for neighbor in scene.adjacency[hovered] {
                lines.move(to: scene.positions[hovered])
                lines.addLine(to: scene.positions[neighbor])
            }
            world.stroke(lines, with: .color(Theme.accent.opacity(0.55)), lineWidth: max(1 / zoom, 0.4))
        }
        let floor = GraphPathCache.minimumScreenRadius / zoom
        var groups: [Int: Path] = [:]
        for i in focus {
            let p = scene.positions[i], r = max(model.radius(ofScene: i), floor)
            groups[model.group(ofScene: i), default: Path()].addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        for (group, path) in groups { world.fill(path, with: .color(color(group))) }
        if let ring = model.hovered ?? model.bestMatch ?? model.selectedSceneIndex, scene.positions.indices.contains(ring) {
            let p = scene.positions[ring], r = max(model.radius(ofScene: ring), floor) + 3 / zoom
            world.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(Theme.textPrimary), lineWidth: 1.5 / zoom)
        }
    }

    private func labels(_ context: inout GraphicsContext, scene: GraphScene, focus: Set<Int>, size: CGSize) {
        var chosen: [Int] = []
        if let hovered = model.hovered { chosen.append(hovered) }
        if let best = model.bestMatch, best != model.hovered { chosen.append(best) }
        if chosen.isEmpty, let center = model.selectedSceneIndex { chosen.append(center) }
        let rest: [Int]
        if !focus.isEmpty {
            rest = Array(focus)
        } else if scene.nodes.count <= 80 {
            rest = Array(scene.nodes.indices)
        } else {
            rest = scene.nodes.indices.filter { model.radius(ofScene: $0) * model.zoom >= (model.localMode ? 6 : 9) }
        }
        let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -20)
        for i in rest.sorted(by: { model.radius(ofScene: $0) > model.radius(ofScene: $1) }) where chosen.count < 60 && !chosen.contains(i) {
            if viewport.contains(model.toView(scene.positions[i])) { chosen.append(i) }
        }
        var placed: [CGRect] = []
        var drawn: [(text: GraphicsContext.ResolvedText, frame: CGRect, primary: Bool)] = []
        for (rank, i) in chosen.enumerated() {
            let p = model.toView(scene.positions[i])
            let r = max(model.radius(ofScene: i) * model.zoom, GraphPathCache.minimumScreenRadius)
            let primary = rank == 0 && (model.hovered != nil || model.bestMatch != nil || model.selectedSceneIndex != nil)
            let text = context.resolve(
                Text(model.title(ofScene: i))
                    .font(primary ? Theme.Font.bodyMedium : Theme.Font.caption)
                    .foregroundStyle(primary ? Theme.textPrimary : Theme.textSecondary)
            )
            let measured = text.measure(in: CGSize(width: 220, height: 40))
            let frame = CGRect(x: p.x - measured.width / 2, y: p.y + r + 3, width: measured.width, height: measured.height)
            let padded = frame.insetBy(dx: -6, dy: -2)
            if placed.contains(where: { $0.intersects(padded) }) { continue }
            placed.append(padded)
            drawn.append((text, frame, primary))
        }
        for label in drawn.reversed() {
            if label.primary {
                let box = label.frame.insetBy(dx: -6, dy: -1)
                context.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(Theme.surfaceHi.opacity(0.92)))
            }
            context.draw(label.text, in: label.frame)
        }
    }

    private func color(_ group: Int) -> Color {
        if group < 0 { return Theme.Graph.ghost }
        return group < Theme.Graph.palette.count ? Theme.Graph.palette[group] : Theme.Graph.other
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
    private var dragging = false

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
        model?.hover(at: nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        downAt = local(event)
        lastDrag = downAt
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let point = local(event)
        guard let start = downAt, let last = lastDrag else { return }
        if !dragging, hypot(point.x - start.x, point.y - start.y) < 3 { return }
        if !dragging { model?.hover(at: nil) }
        dragging = true
        model?.pan(by: CGSize(width: point.x - last.x, height: point.y - last.y))
        lastDrag = point
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            downAt = nil
            lastDrag = nil
            dragging = false
            updateCursor()
        }
        guard !dragging, let model else { return }
        if let path = model.click(at: local(event)) { open?(path) }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
        guard delta != 0 else { return }
        model?.zoom(by: exp(delta), at: local(event))
    }

    override func magnify(with event: NSEvent) {
        model?.zoom(by: 1 + event.magnification, at: local(event))
    }

    private func updateCursor() {
        if model?.hovered != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }
}
