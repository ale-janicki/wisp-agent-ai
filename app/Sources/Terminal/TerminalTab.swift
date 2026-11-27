import SwiftUI
import WispCore

struct TerminalTab: View {
    private let workspace: TerminalWorkspace
    @Environment(\.windowMode) private var windowMode
    @AppStorage("terminal.sidebarCollapsed") private var collapsed = false
    @AppStorage("terminal.sidebarWidth") private var sidebarWidth = Double(Theme.Layout.sidebarWidth)
    @State private var query = ""
    @State private var hovered: UUID?
    @State private var draft = ""
    @State private var resizeStart: Double?
    @State private var dragging: UUID?
    @State private var dragOrigin: UUID?
    @State private var drop: PaneDrop?
    @FocusState private var renameFocused: Bool

    init(workspace: TerminalWorkspace = TerminalStore.shared.workspace) {
        self.workspace = workspace
    }

    private static let widthRange = 160.0...320.0
    private static let rowHeight: CGFloat = 44
    private static let dividerHit: CGFloat = 6
    private static let gripSize = CGSize(width: 36, height: 12)

    var body: some View {
        HStack(spacing: 0) {
            if !collapsed {
                sidebar
                Divider().overlay(Theme.stroke)
            }
            VStack(spacing: 0) {
                if collapsed {
                    toolbar
                    Divider().overlay(Theme.stroke)
                }
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.stroke) }
        .onAppear { workspace.openFirstIfNeeded() }
        .onDisappear { workspace.rememberDirectories() }
        .onChange(of: workspace.renamingTabID) { _, id in
            guard let id, let tab = workspace.layout.tabs.first(where: { $0.id == id }) else { return }
            draft = tab.customTitle ?? info(tab).title
            renameFocused = true
        }
    }

    private var renaming: UUID? { workspace.renamingTabID }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                SearchField(text: $query, placeholder: "Buscar abas…")
                sidebarToggle
            }
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(visibleTabs, id: \.tab.id) { entry in
                        row(entry.tab, index: entry.index)
                    }
                    newTabRow
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(Theme.Space.s)
        .frame(width: clampedWidth)
        .overlay(alignment: .trailing) { resizeHandle }
    }

    private var sidebarToggle: some View {
        Button {
            collapsed.toggle()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(CircleButtonStyle(kind: collapsed ? .plain : .accent, size: Theme.Control.height))
        .keyboardShortcut("b", modifiers: .command)
        .help(collapsed ? "Mostrar abas (⌘B)" : "Esconder abas (⌘B)")
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.s) {
            sidebarToggle
            if let title = selectedTitle {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, Theme.Space.xs)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private var selectedTitle: String? {
        guard let tab = workspace.layout.tabs.first(where: { $0.id == workspace.layout.selectedTabID }) else { return nil }
        return info(tab).title
    }

    private var newTabRow: some View {
        Button {
            workspace.openSession()
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                Text("Nova aba")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(RowButtonStyle(height: Self.rowHeight))
        .help("Nova aba (⌘T)")
    }

    private var clampedWidth: CGFloat {
        CGFloat(min(max(sidebarWidth, Self.widthRange.lowerBound), Self.widthRange.upperBound))
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: Self.dividerHit)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = resizeStart ?? Double(clampedWidth)
                        resizeStart = start
                        sidebarWidth = min(max(start + Double(value.translation.width), Self.widthRange.lowerBound), Self.widthRange.upperBound)
                    }
                    .onEnded { _ in resizeStart = nil })
    }

    private var visibleTabs: [(index: Int, tab: TerminalLayout.Tab)] {
        workspace.layout.tabs.enumerated().compactMap { index, tab in
            let info = info(tab)
            let session = workspace.session(tab.focused)
            let fields = [info.title, info.folder, session?.directory ?? ""]
            return TerminalLayout.matches(query, fields: fields) ? (index, tab) : nil
        }
    }

    private func info(_ tab: TerminalLayout.Tab) -> (title: String, folder: String, activity: TerminalActivity) {
        guard let session = workspace.session(tab.focused) else { return (tab.customTitle ?? "", "", .idle) }
        let title = TerminalTabTitle.make(custom: tab.customTitle, command: session.activity.command, fallback: session.name)
        return (title, TerminalDirectory.abbreviated(session.directory, home: session.home), session.activity)
    }

    private func row(_ tab: TerminalLayout.Tab, index: Int) -> some View {
        let info = info(tab)
        let selected = workspace.layout.selectedTabID == tab.id
        let isHovered = hovered == tab.id
        return ZStack(alignment: .trailing) {
            if renaming == tab.id {
                rowLabel(info, title: renameField(tab))
                    .padding(.horizontal, Theme.Space.m)
                    .frame(height: Self.rowHeight)
                    .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
            } else {
                Button {
                    workspace.selectTab(tab.id)
                } label: {
                    rowLabel(
                        info,
                        title: Text(info.title)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(selected ? Theme.accentText : Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail))
                }
                .buttonStyle(RowButtonStyle(highlight: selected ? .accent : .none, height: Self.rowHeight, hovered: isHovered))
                .simultaneousGesture(TapGesture(count: 2).onEnded { startRenaming(tab, title: info.title) })
                .help(rowHelp(tab, title: info.title, index: index))
            }
            if isHovered, renaming != tab.id {
                Button {
                    workspace.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(CircleButtonStyle(size: 18))
                .padding(.trailing, Theme.Space.s)
                .help("Fechar aba")
            }
        }
        .onHover { inside in
            if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
        }
        .contextMenu {
            Button("Renomear") { startRenaming(tab, title: info.title) }
            Button("Fechar aba") { workspace.closeTab(tab.id) }
        }
    }

    private func rowHelp(_ tab: TerminalLayout.Tab, title: String, index: Int) -> String {
        let directory = workspace.session(tab.focused)?.directory ?? ""
        guard let key = shortcut(index) else { return directory }
        return directory.isEmpty ? "\(title) — \(key)" : "\(title) — \(key)\n\(directory)"
    }

    private func rowLabel(
        _ info: (title: String, folder: String, activity: TerminalActivity), title: some View
    ) -> some View {
        HStack(spacing: Theme.Space.s) {
            TabIcon(state: info.activity.state)
            VStack(alignment: .leading, spacing: 1) {
                title
                Text(info.folder)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
    }

    private func renameField(_ tab: TerminalLayout.Tab) -> some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .focused($renameFocused)
            .onSubmit { finishRenaming(tab.id) }
            .onExitCommand { workspace.renamingTabID = nil }
            .onChange(of: renameFocused) { _, focused in
                if !focused, renaming == tab.id { finishRenaming(tab.id) }
            }
    }

    private func startRenaming(_ tab: TerminalLayout.Tab, title: String) {
        draft = tab.customTitle ?? title
        workspace.renamingTabID = tab.id
        renameFocused = true
    }

    private func finishRenaming(_ id: UUID) {
        guard let tab = workspace.layout.tabs.first(where: { $0.id == id }) else { return }
        if tab.customTitle == nil, draft == info(tab).title {
            workspace.renamingTabID = nil
        } else {
            workspace.rename(id, to: draft)
        }
    }

    private func shortcut(_ index: Int) -> String? {
        if index < 8 { return "⌘\(index + 1)" }
        return index == workspace.layout.tabs.count - 1 ? "⌘9" : nil
    }

    // MARK: Panes

    @ViewBuilder
    private var content: some View {
        if let tab = workspace.layout.selectedTab {
            GeometryReader { proxy in
                panes(tab, size: proxy.size)
            }
            .coordinateSpace(name: Self.paneSpace)
        } else {
            VStack(spacing: Theme.Space.m) {
                Text("Nenhuma sessão aberta")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                Button("Nova sessão") { workspace.openSession() }
                    .buttonStyle(CapsuleButtonStyle(kind: .accent))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static let paneSpace = "terminal.panes"

    private func panes(_ tab: TerminalLayout.Tab, size: CGSize) -> some View {
        let frames = tab.frames
        let split = frames.count > 1
        return ZStack(alignment: .topLeading) {
            ForEach(tab.sessions.filter { frames[$0] != nil }, id: \.self) { id in
                if let rect = frames[id], let session = workspace.session(id), let engine = session.engine as? SwiftTermEngine {
                    pane(session, engine: engine, focused: id == tab.focused, split: split)
                        .frame(width: rect.width * size.width, height: rect.height * size.height)
                        .offset(x: rect.minX * size.width, y: rect.minY * size.height)
                }
            }
            ForEach(tab.dividers, id: \.path) { divider in
                dividerHandle(divider, size: size)
            }
            if split {
                ForEach(tab.sessions.filter { frames[$0] != nil }, id: \.self) { id in
                    if let rect = frames[id] { dragGrip(id, in: rect, size: size) }
                }
            }
            if let drop, let rect = frames[drop.session] {
                dropHighlight(drop.edge, in: rect, size: size)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func pane(_ session: TerminalSession, engine: SwiftTermEngine, focused: Bool, split: Bool) -> some View {
        VStack(spacing: 0) {
            TerminalSurface(
                engine: engine, session: session,
                fontSize: windowMode ? TerminalTheme.windowFontSize : TerminalTheme.compactFontSize,
                isFocused: focused, workspace: workspace)
                .padding(.leading, Theme.Space.s)
            if let note = endedNote(session) {
                HStack(spacing: Theme.Space.m) {
                    Text(note)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Button("Reabrir") { session.reopen() }
                        .buttonStyle(CapsuleButtonStyle(kind: .accent, size: .compact))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(height: 38)
                .background(Theme.surface)
            }
        }
        .overlay(alignment: .topLeading) {
            if split, focused {
                ActivePaneMark().allowsHitTesting(false)
            }
        }
        .onHover { inside in
            guard inside, !focused, dragging == nil, workspace.renamingTabID == nil, TerminalPaneKeys.hoverMayMoveFocus(in: NSApp.keyWindow) else { return }
            workspace.select(session.id)
        }
    }

    private func dragGrip(_ id: UUID, in rect: CGRect, size: CGSize) -> some View {
        Capsule()
            .fill(dragging == id ? Theme.accent : Theme.stroke)
            .frame(width: Self.gripSize.width, height: 4)
            .frame(width: Self.gripSize.width, height: Self.gripSize.height)
            .contentShape(Rectangle())
            .pointerStyle(.grabIdle)
            .offset(x: (rect.midX * size.width) - Self.gripSize.width / 2, y: rect.minY * size.height)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.paneSpace))
                    .onChanged { value in
                        guard size.width > 0, size.height > 0, let tab = workspace.layout.selectedTab else { return }
                        if dragging == nil { dragOrigin = tab.focused }
                        dragging = id
                        let point = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                        drop = TerminalLayout.dropTarget(at: point, in: tab.frames, excluding: id).map { PaneDrop(session: $0.session, edge: $0.edge) }
                    }
                    .onEnded { _ in
                        if let drop {
                            workspace.move(id, onto: drop.session, edge: drop.edge)
                        } else if let dragOrigin {
                            workspace.select(dragOrigin)
                        }
                        dragOrigin = nil
                        dragging = nil
                        drop = nil
                    })
    }

    private func dropHighlight(_ edge: TerminalLayout.DropEdge, in rect: CGRect, size: CGSize) -> some View {
        var zone = rect
        switch edge {
        case .left: zone.size.width /= 2
        case .right: zone.size.width /= 2; zone.origin.x = rect.midX
        case .top: zone.size.height /= 2
        case .bottom: zone.size.height /= 2; zone.origin.y = rect.midY
        case .center: break
        }
        return RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Theme.accent.opacity(0.25))
            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.accent) }
            .frame(width: zone.width * size.width, height: zone.height * size.height)
            .offset(x: zone.minX * size.width, y: zone.minY * size.height)
            .allowsHitTesting(false)
    }

    private func dividerHandle(_ divider: TerminalLayout.Divider, size: CGSize) -> some View {
        let bounds = divider.bounds
        let horizontal = divider.axis == .horizontal
        let x = horizontal ? (bounds.minX + bounds.width * divider.ratio) * size.width - Self.dividerHit / 2 : bounds.minX * size.width
        let y = horizontal ? bounds.minY * size.height : (bounds.minY + bounds.height * divider.ratio) * size.height - Self.dividerHit / 2
        return ZStack {
            Rectangle()
                .fill(Theme.stroke)
                .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
        }
        .frame(
            width: horizontal ? Self.dividerHit : bounds.width * size.width,
            height: horizontal ? bounds.height * size.height : Self.dividerHit)
        .contentShape(Rectangle())
        .pointerStyle(horizontal ? .columnResize : .rowResize)
        .offset(x: x, y: y)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.paneSpace))
                .onChanged { value in
                    guard size.width > 0, size.height > 0 else { return }
                    let point = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                    workspace.resize(divider.path, to: divider.ratio(at: point))
                })
    }

    private func endedNote(_ session: TerminalSession) -> String? {
        switch session.phase {
        case .ended(let code): code.map { "Código de saída \($0)" } ?? "Encerrado por um sinal"
        case .failed(let reason): reason
        case .idle, .running: nil
        }
    }
}

private struct PaneDrop: Equatable {
    let session: UUID
    let edge: TerminalLayout.DropEdge
}

private struct ActivePaneMark: View {
    var body: some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 10, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 10))
            path.closeSubpath()
        }
        .fill(Theme.accent)
        .frame(width: 10, height: 10)
    }
}

private struct TabIcon: View {
    let state: TerminalActivity.State

    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 22, height: 22)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(badge.color)
                        .background(Circle().fill(Theme.bg).padding(-1))
                        .offset(x: 3, y: 3)
                }
            }
    }

    private var badge: (symbol: String, color: Color)? {
        switch state {
        case .idle: nil
        case .running: ("circle.lefthalf.filled", Theme.accent)
        case .succeeded: ("checkmark.circle.fill", Theme.ok)
        case .failed: ("xmark.circle.fill", Theme.error)
        }
    }
}
