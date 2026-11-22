import AppKit
import SwiftUI
import WispCore

struct BrainCanvasView: View {
    let url: URL
    let vaultRoot: URL?
    let onOpenNote: (String) -> Void
    let onNotice: (String) -> Void
    @State private var model: BrainCanvasModel?

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            if let model {
                CanvasSurface(model: model)
            } else {
                Spacer()
            }
        }
        .padding(Theme.Space.m)
        .task(id: url) {
            model?.stop()
            let next = BrainCanvasModel(url: url, vaultRoot: vaultRoot, openNote: onOpenNote, onNotice: onNotice)
            model = next
            next.start()
        }
        .onDisappear { model?.stop() }
    }
}

private struct CanvasSurface: View {
    @Bindable var model: BrainCanvasModel
    @State private var panStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var promptKind: CanvasNode.Kind?
    @State private var promptText = ""
    @State private var editingTextID: String?
    @State private var editingText = ""

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            DrawingToolbar(title: model.url.lastPathComponent, editing: $model.editing, note: model.saveNote, readOnlyNotice: model.readOnlyNotice) {
                HStack(spacing: 2) {
                    Button("−") { model.zoom(by: 1 / 1.25) }
                    Button("Ajustar") { model.fit() }
                    Button("+") { model.zoom(by: 1.25) }
                }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
            }
            if let notice = model.readOnlyNotice { InlineError(text: notice) }
            if model.editing { editBar }
            if model.externalChangePending {
                ExternalChangeBanner(reload: model.reloadFromDisk, overwrite: model.overwriteDisk)
            }
            if case .failed(let message) = model.status {
                InlineError(text: message)
            }
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Theme.Graph.well
                    CanvasEdgesLayer(model: model)
                    ForEach(model.canvas.nodes) { node in
                        CanvasNodeView(model: model, node: node, beginEditingText: beginEditing)
                    }
                    ScrollWheelCatcher { delta, zoom, location in
                        if zoom {
                            model.zoom(by: exp(delta.height * 0.01), around: location)
                        } else {
                            model.pan = CGSize(width: model.pan.width + delta.width, height: model.pan.height + delta.height)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(panGesture)
                .simultaneousGesture(magnifyGesture)
                .onTapGesture { model.selection = nil; model.connectingFrom = nil }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
                .onAppear { model.setViewport(proxy.size) }
                .onChange(of: proxy.size) { _, size in model.setViewport(size) }
            }
        }
        .alert(promptTitle, isPresented: Binding(get: { promptKind != nil }, set: { if !$0 { promptKind = nil } })) {
            TextField(promptPlaceholder, text: $promptText)
            Button("Adicionar") {
                if let kind = promptKind { model.addNode(kind, text: promptText) }
                promptKind = nil
            }
            Button("Cancelar", role: .cancel) { promptKind = nil }
        }
        .alert("Editar texto", isPresented: Binding(get: { editingTextID != nil }, set: { if !$0 { editingTextID = nil } })) {
            TextField("Texto", text: $editingText, axis: .vertical)
            Button("Salvar") {
                if let id = editingTextID { model.setText(editingText, for: id) }
                editingTextID = nil
            }
            Button("Cancelar", role: .cancel) { editingTextID = nil }
        }
    }

    private var promptTitle: String {
        switch promptKind {
        case .file: "Nota ou arquivo"
        case .link: "Link"
        case .group: "Grupo"
        default: "Texto"
        }
    }

    private var promptPlaceholder: String {
        switch promptKind {
        case .file: "pasta/nota.md"
        case .link: "https://"
        case .group: "Nome do grupo"
        default: "Texto"
        }
    }

    private var editBar: some View {
        HStack(spacing: Theme.Space.s) {
            Group {
                Button("+ Texto") { model.addNode(.text, text: "Novo cartão") }
                Button("+ Nota") { promptText = ""; promptKind = .file }
                Button("+ Link") { promptText = ""; promptKind = .link }
                Button("+ Grupo") { promptText = ""; promptKind = .group }
                Button(model.connectingFrom == nil ? "Conectar" : "Escolha o destino…") {
                    model.connectingFrom = model.connectingFrom == nil ? model.selection : nil
                }
                .disabled(model.selection == nil && model.connectingFrom == nil)
                Button("Apagar") { model.deleteSelection() }
                    .disabled(model.selection == nil)
            }
            .buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
            Spacer(minLength: 0)
        }
    }

    private func beginEditing(_ node: CanvasNode) {
        editingText = (node.kind == .group ? node.label : node.text) ?? ""
        editingTextID = node.id
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let start = panStart ?? model.pan
                panStart = start
                model.pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? model.scale
                zoomStart = start
                model.zoom(by: (start * value.magnification) / model.scale, around: value.startLocation)
            }
            .onEnded { _ in zoomStart = nil }
    }
}

private struct CanvasEdgesLayer: View {
    let model: BrainCanvasModel

    var body: some View {
        Canvas { context, _ in
            for edge in model.canvas.edges {
                guard let from = model.canvas.node(edge.fromNode), let to = model.canvas.node(edge.toNode) else { continue }
                let fromSide = edge.fromSide ?? JSONCanvas.bestSides(from: from, to: to).0
                let toSide = edge.toSide ?? JSONCanvas.bestSides(from: from, to: to).1
                let start = point(of: from, side: fromSide)
                let end = point(of: to, side: toSide)
                let reach = max(40, hypot(end.x - start.x, end.y - start.y) * 0.35)
                let c1 = control(start, side: fromSide, reach: reach)
                let c2 = control(end, side: toSide, reach: reach)
                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: c1, control2: c2)
                let color = CanvasPalette.color(edge.color) ?? Theme.textTertiary
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(1, 1.5 * model.scale), lineCap: .round))
                if edge.toArrow { arrowhead(&context, tip: end, from: c2, color: color) }
                if edge.fromArrow { arrowhead(&context, tip: start, from: c1, color: color) }
                if let label = edge.label, !label.isEmpty {
                    let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                    let text = context.resolve(Text(label).font(.system(size: max(9, 12 * model.scale))).foregroundColor(Theme.textSecondary))
                    let size = text.measure(in: CGSize(width: 400, height: 80))
                    let box = CGRect(x: mid.x - size.width / 2 - 4, y: mid.y - size.height / 2 - 2, width: size.width + 8, height: size.height + 4)
                    context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Theme.bg))
                    context.draw(text, at: mid)
                }
            }
        }
    }

    private func point(of node: CanvasNode, side: CanvasEdge.Side) -> CGPoint {
        let anchor = JSONCanvas.anchor(of: node, side: side)
        let shift = model.dragging.flatMap { $0.ids.contains(node.id) ? $0.delta : nil } ?? .zero
        return CGPoint(x: anchor.x * model.scale + model.pan.width + shift.width, y: anchor.y * model.scale + model.pan.height + shift.height)
    }

    private func control(_ point: CGPoint, side: CanvasEdge.Side, reach: CGFloat) -> CGPoint {
        switch side {
        case .top: CGPoint(x: point.x, y: point.y - reach)
        case .bottom: CGPoint(x: point.x, y: point.y + reach)
        case .left: CGPoint(x: point.x - reach, y: point.y)
        case .right: CGPoint(x: point.x + reach, y: point.y)
        }
    }

    private func arrowhead(_ context: inout GraphicsContext, tip: CGPoint, from control: CGPoint, color: Color) {
        let angle = atan2(tip.y - control.y, tip.x - control.x)
        let size = max(8, 10 * model.scale)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: tip.x - size * cos(angle - .pi / 7), y: tip.y - size * sin(angle - .pi / 7)))
        head.addLine(to: CGPoint(x: tip.x - size * cos(angle + .pi / 7), y: tip.y - size * sin(angle + .pi / 7)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

private struct CanvasNodeView: View {
    let model: BrainCanvasModel
    let node: CanvasNode
    let beginEditingText: (CanvasNode) -> Void
    @State private var resizing: CGSize?

    private var scale: CGFloat { model.scale }
    private var size: CGSize {
        resizing ?? CGSize(width: node.width * scale, height: node.height * scale)
    }
    private var selected: Bool { model.selection == node.id }
    private var tint: Color { CanvasPalette.color(node.color) ?? Theme.textTertiary }

    var body: some View {
        let origin = model.screenOrigin(of: node)
        content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(background)
            .overlay {
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : tint.opacity(node.color == nil ? 0.5 : 1), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: node.kind == .group ? [6, 4] : []))
            }
            .overlay(alignment: .bottomTrailing) { resizeHandle }
            .clipShape(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
            .contentShape(Rectangle())
            .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            .onTapGesture(count: 2) {
                if model.editing {
                    if node.kind == .text || node.kind == .group { beginEditingText(node) } else { model.activate(node) }
                }
            }
            .onTapGesture { model.tap(node) }
            .gesture(moveGesture)
            .pointerStyle(node.kind == .file || node.kind == .link ? .link : nil)
    }

    @ViewBuilder private var background: some View {
        switch node.kind {
        case .group: tint.opacity(0.06)
        default: Theme.surface.overlay(tint.opacity(node.color == nil ? 0 : 0.14))
        }
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .text: CanvasMarkdown(text: node.text ?? "", scale: scale).padding(10 * scale)
        case .file: fileContent
        case .link:
            VStack(alignment: .leading, spacing: 4 * scale) {
                Label("Link", systemImage: "link").font(.system(size: max(9, 11 * scale), weight: .medium)).foregroundStyle(Theme.textTertiary)
                Text(node.url ?? "").font(.system(size: max(9, 13 * scale))).foregroundStyle(Theme.accentText).lineLimit(3)
            }
            .padding(10 * scale)
        case .group:
            Text(node.label ?? "")
                .font(.system(size: max(9, 12 * scale), weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(8 * scale)
        case nil:
            Text("Nó desconhecido").font(.system(size: max(9, 12 * scale))).foregroundStyle(Theme.textTertiary).padding(8 * scale)
        }
    }

    @ViewBuilder private var fileContent: some View {
        if let image = model.images[node.id] {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            VStack(alignment: .leading, spacing: 4 * scale) {
                Label("Nota", systemImage: "doc.text").font(.system(size: max(9, 11 * scale), weight: .medium)).foregroundStyle(Theme.textTertiary)
                Text(((node.file ?? "") as NSString).lastPathComponent)
                    .font(.system(size: max(9, 13 * scale), weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                if let subpath = node.subpath {
                    Text(subpath).font(.system(size: max(9, 11 * scale))).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(10 * scale)
        }
    }

    @ViewBuilder private var resizeHandle: some View {
        if model.editing, selected {
            Image(systemName: "arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.bg)
                .frame(width: 16, height: 16)
                .background(Theme.accent, in: Circle())
                .padding(3)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            resizing = CGSize(
                                width: max(40 * scale, node.width * scale + value.translation.width),
                                height: max(30 * scale, node.height * scale + value.translation.height)
                            )
                        }
                        .onEnded { _ in
                            if let final = resizing { model.resize(node.id, to: final) }
                            resizing = nil
                        }
                )
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard model.editing else { return }
                if model.dragging == nil {
                    model.selection = node.id
                    model.dragging = BrainCanvasModel.Dragging(ids: model.beginDrag(of: node), delta: .zero)
                }
                model.dragging?.delta = value.translation
            }
            .onEnded { _ in model.commitDrag() }
    }
}

private struct CanvasMarkdown: View {
    let text: String
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ line: String) -> Text {
        var body = line
        var weight = Font.Weight.regular
        var size: CGFloat = 13
        if let level = headingLevel(line) {
            body = String(line.dropFirst(level + 1))
            weight = .bold
            size = 13 + CGFloat(max(0, 4 - level)) * 3
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            body = "•  " + line.dropFirst(2)
        }
        let attributed = (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body)
        return Text(attributed).font(.system(size: max(8, size * scale), weight: weight)).foregroundColor(Theme.textPrimary)
    }

    private func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        return (1...6).contains(hashes) && line.dropFirst(hashes).hasPrefix(" ") ? hashes : nil
    }
}

enum CanvasPalette {
    @MainActor static func color(_ value: String?) -> Color? {
        guard let value else { return nil }
        switch value {
        case "1": return Theme.error
        case "2": return Color(hex: 0xFB923C)
        case "3": return Theme.busy
        case "4": return Theme.ok
        case "5": return Theme.accentTeal
        case "6": return Color(hex: 0xC084FC)
        default:
            let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
            guard digits.count == 6, let number = UInt32(digits, radix: 16) else { return nil }
            return Color(hex: number)
        }
    }
}

struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGSize, Bool, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: (CGSize, Bool, CGPoint) -> Void = { _, _, _ in }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local) else { return event }
                let zoom = event.modifierFlags.contains(.command)
                let delta = CGSize(width: event.scrollingDeltaX, height: zoom ? event.scrollingDeltaY : event.scrollingDeltaY)
                let flipped = CGPoint(x: local.x, y: self.isFlipped ? local.y : self.bounds.height - local.y)
                self.onScroll(delta, zoom, flipped)
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
