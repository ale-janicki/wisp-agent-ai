import SwiftUI
import WispCore

/// The Terminal tab: a sidebar of tabs on the left (Warp's vertical tabs) and the selected tab's panes beside it. Compact in the
/// notch panel, with a bigger font in the window; the panes fill whatever room the container has.
struct TerminalTab: View {
    private let workspace = TerminalStore.shared.workspace
    @Environment(\.windowMode) private var windowMode
    @AppStorage("terminal.sidebarCollapsed") private var collapsed = false
    @AppStorage("terminal.sidebarWidth") private var sidebarWidth = Double(Theme.Layout.sidebarWidth)
    @State private var query = ""
    @State private var hovered: UUID?
    @State private var draft = ""
    @State private var resizeStart: Double?
    @FocusState private var renameFocused: Bool

    private static let widthRange = 160.0...320.0
    private static let rowHeight: CGFloat = 44
    private static let dividerHit: CGFloat = 6

    var body: some View {
        HStack(spacing: 0) {
            if collapsed { rail } else { sidebar }
            Divider().overlay(Theme.stroke)
            content
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
            HStack(spacing: Theme.Space.xs) {
                collapseButton
                Spacer(minLength: 0)
                newTabButton
            }
            SearchField(text: $query, placeholder: "Buscar abas…")
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(visibleTabs, id: \.tab.id) { entry in
                        row(entry.tab, index: entry.index)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(Theme.Space.s)
        .frame(width: clampedWidth)
        .overlay(alignment: .trailing) { resizeHandle }
    }

    /// The collapsed sidebar: only the buttons to open it again and to add a tab.
    private var rail: some View {
        VStack(spacing: Theme.Space.s) {
            collapseButton
            newTabButton
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.s)
        .frame(width: Theme.Control.compactHeight + 2 * Theme.Space.s)
    }

    private var collapseButton: some View {
        Button {
            collapsed.toggle()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
        .help(collapsed ? "Mostrar abas" : "Esconder abas")
    }

    private var newTabButton: some View {
        Button {
            workspace.openSession()
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
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

    /// The tabs the search leaves, each with its place among all of them (⌘1…⌘9 count every tab, not the ones shown).
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
                // The field lives outside the row's button, so its clicks and keys reach the text and not the button.
                rowLabel(info, title: renameField(tab), shortcut: nil)
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
                            .truncationMode(.tail),
                        shortcut: isHovered ? nil : shortcut(index))
                }
                .buttonStyle(RowButtonStyle(highlight: selected ? .accent : .none, height: Self.rowHeight, hovered: isHovered))
                .simultaneousGesture(TapGesture(count: 2).onEnded { startRenaming(tab, title: info.title) })
                .help(workspace.session(tab.focused)?.directory ?? "")
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

    private func rowLabel(
        _ info: (title: String, folder: String, activity: TerminalActivity), title: some View, shortcut: String?
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
            if let shortcut {
                Text(shortcut)
                    .font(Theme.Font.captionMono)
                    .foregroundStyle(Theme.textTertiary)
            }
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

    /// An empty name gives the tab its automatic title back; leaving the automatic title as it was keeps it automatic.
    private func finishRenaming(_ id: UUID) {
        guard let tab = workspace.layout.tabs.first(where: { $0.id == id }) else { return }
        if tab.customTitle == nil, draft == info(tab).title {
            workspace.renamingTabID = nil
        } else {
            workspace.rename(id, to: draft)
        }
    }

    /// ⌘1…⌘8 name the first eight tabs and ⌘9 the last one, as in Warp.
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

    /// Every visible pane is keyed by its session, so a split or a close moves the existing screens instead of making new ones.
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
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func pane(_ session: TerminalSession, engine: SwiftTermEngine, focused: Bool, split: Bool) -> some View {
        VStack(spacing: 0) {
            TerminalSurface(
                engine: engine, session: session,
                fontSize: windowMode ? TerminalTheme.windowFontSize : TerminalTheme.compactFontSize,
                isFocused: focused)
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
        // Focus follows the pointer between panes, as in Warp; never away from a text field that has the keyboard.
        .onHover { inside in
            guard inside, !focused, workspace.renamingTabID == nil, TerminalPaneKeys.hoverMayMoveFocus(in: NSApp.keyWindow) else { return }
            workspace.select(session.id)
        }
    }

    /// The line between two panes, with a wider strip to grab; dragging it sets the split's ratio from the pointer.
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

/// The small accent triangle in the top left corner of the pane that has the keyboard.
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

/// A tab's icon with what its focused pane's last command is doing: a half moon while one runs, a check or a red cross for how it
/// ended, nothing when idle. Static on purpose: no animation runs for a long-lived server.
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
