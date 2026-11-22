import AppKit
import SwiftUI
import WispCore

struct BrainReaderView: View {
    let tab: BrainOpenNote
    var model: BrainModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    BrainPropertiesView(tab: tab, model: model)
                    ForEach(tab.render.nodes) { node in
                        BrainBlockView(node: node, source: tab.path, model: model, depth: 0)
                            .id(node.line)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .environment(\.openURL, OpenURLAction { url in BrainLinks.handle(url, source: tab.path, model: model) })
            .onChange(of: tab.jumpSeq) { _, _ in
                guard let line = tab.jumpLine else { return }
                let target = tab.render.nodes.last { $0.line <= line }?.line ?? line
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
            }
            .task(id: tab.revision) {
                guard let line = tab.jumpLine, tab.jumpSeq > 0 else { return }
                try? await Task.sleep(for: .milliseconds(80))
                let target = tab.render.nodes.last { $0.line <= line }?.line ?? line
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }
}

@MainActor
enum BrainLinks {
    static func handle(_ url: URL, source: String, model: BrainModel) -> OpenURLAction.Result {
        guard let action = BrainLinkScheme.action(for: url) else {
            switch BrainLinkPolicy.decide(url) {
            case .open: NSWorkspace.shared.open(url)
            case .reveal:
                if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            case .refuse: model.message = "Não abro links \(url.scheme ?? "sem esquema"): por segurança."
            }
            return .handled
        }
        switch action {
        case .note(let link, _):
            model.follow(link, from: source, newTab: NSEvent.modifierFlags.contains(.command))
        case .tag(let name):
            model.searchQuery = "#" + name
            model.showsSearch = true
        }
        return .handled
    }
}

struct BrainBlockView: View {
    let node: BrainBlockNode
    let source: String
    var model: BrainModel
    let depth: Int

    private func text(_ inline: [BrainInline], size: CGFloat = 13, bold: Bool = false) -> Text {
        var style = BrainInlineStyle()
        style.size = size
        style.bold = bold
        return Text(BrainInlineText.attributed(inline, style: style) { model.resolve($0, from: source) != nil })
    }

    var body: some View {
        switch node.block {
        case .heading(let level, let inline):
            let sizes: [CGFloat] = [22, 19, 16.5, 15, 14, 13]
            text(inline, size: sizes[min(level, 6) - 1], bold: true)
                .padding(.top, level <= 2 ? 8 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let inline):
            text(inline)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    BrainListItemView(item: item, marker: ordered ? "\(start + index)." : "•", source: source, model: model, depth: depth)
                }
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: Theme.Space.s) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.textTertiary).frame(width: 3)
                BrainBlocksView(blocks: blocks, source: source, model: model, depth: depth)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .callout(let kind, let title, let foldable, let collapsed, let body):
            BrainCalloutView(kind: kind, title: title, foldable: foldable, collapsed: collapsed, content: body, source: source, model: model, depth: depth)
        case .code(_, let code):
            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(Theme.Font.tool)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(Theme.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
        case .table(let header, let alignments, let rows):
            BrainTableView(header: header, alignments: alignments, rows: rows, source: source, model: model)
        case .rule:
            Divider().overlay(Theme.stroke)
        case .embed(let embed):
            BrainEmbedView(embed: embed, source: source, model: model, depth: depth)
        case .footnotes(let notes):
            VStack(alignment: .leading, spacing: 4) {
                Divider().overlay(Theme.stroke)
                ForEach(notes, id: \.label) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("[\(note.label)]").font(Theme.Font.caption).foregroundStyle(Theme.accent)
                        text(note.content, size: 12).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }
}

struct BrainBlocksView: View {
    let blocks: [BrainBlockNode]
    let source: String
    var model: BrainModel
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { node in
                BrainBlockView(node: node, source: source, model: model, depth: depth)
            }
        }
    }
}

private struct BrainListItemView: View {
    let item: BrainListItem
    let marker: String
    let source: String
    var model: BrainModel
    let depth: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let task = item.task {
                Button {
                    model.toggleTask(line: item.line, raw: item.raw)
                } label: {
                    Image(systemName: task == .done ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(task == .done ? Theme.accent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(task == .done ? "Desmarcar" : "Concluir")
            } else {
                Text(marker)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(minWidth: 14, alignment: .trailing)
            }
            BrainBlocksView(blocks: item.blocks, source: source, model: model, depth: depth)
                .opacity(item.task == .done ? 0.55 : 1)
        }
    }
}

private struct BrainCalloutView: View {
    let kind: String
    let title: [BrainInline]
    let foldable: Bool
    let collapsed: Bool
    let content: [BrainBlockNode]
    let source: String
    var model: BrainModel
    let depth: Int
    @State private var folded: Bool

    init(kind: String, title: [BrainInline], foldable: Bool, collapsed: Bool, content: [BrainBlockNode], source: String, model: BrainModel, depth: Int) {
        self.kind = kind
        self.title = title
        self.foldable = foldable
        self.collapsed = collapsed
        self.content = content
        self.source = source
        self.model = model
        self.depth = depth
        _folded = State(initialValue: collapsed)
    }

    private var style: (icon: String, color: Color) {
        switch kind {
        case "tip", "hint", "important": ("flame", Theme.accentTeal)
        case "warning", "caution", "attention": ("exclamationmark.triangle", Theme.busy)
        case "danger", "error", "bug", "failure", "fail", "missing": ("xmark.octagon", Theme.error)
        case "success", "check", "done": ("checkmark.circle", Theme.ok)
        case "question", "help", "faq": ("questionmark.circle", Theme.busy)
        case "quote", "cite": ("quote.opening", Theme.textTertiary)
        case "example": ("list.bullet", Color(hex: 0xC084FC))
        case "abstract", "summary", "tldr": ("doc.text", Theme.accentTeal)
        case "todo": ("checkmark.circle", Color(hex: 0x60A5FA))
        default: ("info.circle", Color(hex: 0x60A5FA))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if foldable { withAnimation(.easeOut(duration: 0.15)) { folded.toggle() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: style.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(style.color)
                    Text(BrainInlineText.attributed(title, style: calloutTitle) { model.resolve($0, from: source) != nil })
                    Spacer(minLength: 0)
                    if foldable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(folded ? 0 : 90))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !folded, !content.isEmpty {
                BrainBlocksView(blocks: content, source: source, model: model, depth: depth)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(style.color).frame(width: 3).padding(.vertical, 6) }
    }

    private var calloutTitle: BrainInlineStyle {
        var style = BrainInlineStyle()
        style.bold = true
        style.color = self.style.color
        return style
    }
}

private struct BrainTableView: View {
    let header: [[BrainInline]]
    let alignments: [BrainAlignment]
    let rows: [[[BrainInline]]]
    let source: String
    var model: BrainModel

    private func cell(_ inline: [BrainInline], _ column: Int, bold: Bool) -> some View {
        var style = BrainInlineStyle()
        style.bold = bold
        let text = Text(BrainInlineText.attributed(inline, style: style) { model.resolve($0, from: source) != nil })
        let alignment: Alignment = alignments.indices.contains(column) ? (alignments[column] == .center ? .center : (alignments[column] == .trailing ? .trailing : .leading)) : .leading
        return text.padding(.horizontal, 8).padding(.vertical, 5).frame(minWidth: 60, alignment: alignment)
    }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, inline in cell(inline, column, bold: true) }
                }
                .background(Theme.surfaceHi)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, inline in cell(inline, column, bold: false) }
                    }
                    .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1) }
        }
        .scrollIndicators(.hidden)
    }
}

struct BrainEmbedView: View {
    let embed: BrainEmbed
    let source: String
    var model: BrainModel
    let depth: Int
    @State private var image: NSImage?
    @State private var embedded: BrainRenderModel?
    @State private var collapsed = false
    @State private var failed = false

    private var targetPath: String? {
        switch embed.kind {
        case .note: model.resolve(BrainWikiLink(name: embed.name, heading: embed.heading), from: source)
        default: model.resolveFile(embed.name, from: source)
        }
    }

    var body: some View {
        Group {
            switch embed.kind {
            case .image: imageBody
            case .drawing: drawingBody
            case .attachment: attachmentBody
            case .note: noteBody
            }
        }
    }

    private var missing: some View {
        Label("Não encontrei \(embed.name)", systemImage: "questionmark.square.dashed")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
    }

    @ViewBuilder
    private var imageBody: some View {
        if let path = targetPath, let url = model.url(for: path) {
            Group {
                if let image {
                    let width = embed.option.flatMap { Double($0.split(separator: "x").first ?? "") }
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: width.map { CGFloat($0) } ?? image.size.width, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
                } else if failed {
                    missing
                } else {
                    Skeleton(cornerRadius: Theme.Radius.artwork).frame(height: 80)
                }
            }
            .task(id: path) {
                let loaded = await Task.detached { NSImage(contentsOf: url) }.value
                image = loaded
                failed = loaded == nil
            }
        } else {
            missing
        }
    }

    @ViewBuilder
    private var drawingBody: some View {
        if let path = targetPath, let url = model.url(for: path) {
            BrainDrawingView(url: url)
        } else {
            missing
        }
    }

    @ViewBuilder
    private var attachmentBody: some View {
        if let path = targetPath, let url = model.url(for: path) {
            Button { NSWorkspace.shared.open(url) } label: {
                Label(embed.name, systemImage: "paperclip").font(Theme.Font.bodyMedium)
            }
            .buttonStyle(CompactCapsuleStyle(accent: false))
        } else {
            missing
        }
    }

    @ViewBuilder
    private var noteBody: some View {
        if let path = targetPath {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text(BrainTree.displayName(path, isFolder: false) + (embed.heading.isEmpty ? "" : " > " + embed.heading))
                            .font(Theme.Font.caption)
                        Spacer(minLength: 0)
                        Button { model.open(path, heading: embed.heading.isEmpty ? nil : embed.heading) } label: { Image(systemName: "arrow.up.right.square") }
                            .buttonStyle(.plain)
                            .help("Abrir a nota")
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !collapsed {
                    if depth >= 3 {
                        Text("Limite de notas dentro de notas.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    } else if let embedded {
                        BrainBlocksView(blocks: embedded.nodes, source: path, model: model, depth: depth + 1)
                    } else if failed {
                        missing
                    } else {
                        Skeleton(cornerRadius: Theme.Radius.artwork).frame(height: 40)
                    }
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceHi.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent.opacity(0.6)).frame(width: 3).padding(.vertical, 6) }
            .task(id: "\(path)|\(embed.heading)|\(model.scanTick)|\(collapsed)") {
                guard !collapsed, depth < 3, let files = model.files else { return }
                let heading = embed.heading
                let result = await Task.detached { () -> BrainRenderModel? in
                    guard let text = try? files.read(path) else { return nil }
                    let body = BrainDocument(text).body
                    return BrainMarkdown.parse(heading.isEmpty ? body : (BrainSections.extract(body, heading: heading) ?? body))
                }.value
                embedded = result
                failed = result == nil
            }
        } else {
            missing
        }
    }
}
