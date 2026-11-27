import AppKit
import SwiftUI
import WispCore

struct PanelView: View {
    @ObservedObject var controller: ShellController
    @ObservedObject var media: NowPlayingService
    var model: ConversationViewModel
    @State private var draft = ""
    @State private var settingsTab: PanelTab?
    @State private var navCovered = false
    @State private var titlebarInset: CGFloat = 0
    @State private var railHovered = false
    @Environment(\.windowMode) private var windowMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if DEBUG
    nonisolated(unsafe) static var snapshotRailExpanded = false
    #endif

    init(controller: ShellController, media: NowPlayingService, model: ConversationViewModel) {
        self.controller = controller
        self.media = media
        self.model = model
    }

    private static let headerHeight: CGFloat = 56

    private var padding: CGFloat { Theme.Layout.panelPadding }

    private static let topInset: CGFloat = 2
    private static let avatarSize: CGFloat = 36
    /// Rail layout: icon rows are 42 wide plus a 10 gap to the content.
    private static let railSlot: CGFloat = 52

    private var railMode: Bool { controller.tab.hasSecondaryColumn }

    private var railExpanded: Bool {
        #if DEBUG
        if Self.snapshotRailExpanded { return railMode }
        #endif
        return railMode && railHovered
    }

    private var railAnimation: Animation? { reduceMotion ? nil : Self.slide }

    /// Only the notch reserves space at the top. The panel sits under the notch, so it clears `notchHeight`. The window
    /// lays out from its very top (fullscreen already sits below the notch), so the content starts on the line of the
    /// sidebar header's avatar top, below the titlebar like the sidebar column.
    private var contentTopInset: CGFloat {
        if windowMode { return titlebarInset + Self.topInset + (Self.headerHeight - Self.avatarSize) / 2 }
        guard controller.notchWidth > 0 else { return padding }
        return max(controller.notchHeight, padding)
    }

    var body: some View {
        Group {
            if model.profileError != nil {
                VStack(spacing: 0) {
                    header()
                    OnboardingView(model: model) {}
                }
                .padding(.top, titlebarInset)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    sidebarSlot
                        .zIndex(1)
                    if railMode, controller.tab == .conversation {
                        ConversationListColumn(controller: controller, model: model)
                            .padding(.trailing, Theme.Space.m)
                            .padding(.top, contentTopInset)
                            .frame(width: Theme.Layout.sidebarWidth - padding)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                    content
                        .padding(.top, contentTopInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .environment(\.openTabSettings) { settingsTab = $0 }
        .environment(\.navCover, NavCover(isCovered: navCovered) { covered in
            withAnimation(Self.slide) { navCovered = covered }
        })
        .onChange(of: controller.tab) { old, tab in
            settingsTab = nil
            if !(old.hasSecondaryColumn && tab.hasSecondaryColumn) { railHovered = false }
            if tab != .meetings { navCovered = false }
        }
        .padding(.horizontal, padding)
        .padding(.bottom, padding)
        .background {
            if windowMode { TitlebarInsetReader(inset: $titlebarInset) }
        }
    }

    // MARK: Header

    private func header(compact: Bool = false) -> some View {
        HStack(spacing: 10) {
            WispAvatar(size: Self.avatarSize, busy: controller.statusColor == .busy, imagePath: model.profile.persona.avatar)
            if !compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.personaName)
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusLabel)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                        if let status = model.state.status, !status.isEmpty {
                            Text(status)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !windowMode {
                Button {
                    controller.openWindow()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                .help("Abrir em janela (⌘⇧W)")
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .opacity(compact ? 0 : 1)
                .frame(width: compact ? 0 : nil)
                .allowsHitTesting(!compact)
                .accessibilityHidden(compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.headerHeight)
        .padding(.top, Self.topInset)
    }

    private var statusColor: Color {
        model.inputBlocked ? Theme.busy : controller.statusColor.color
    }

    private var statusLabel: String {
        if model.onboarding == .localChecking { return "Verificando…" }
        if model.inputBlocked { return "Configuração pendente" }
        switch controller.statusColor {
        case .ok: return "Pronto"
        case .busy: return "Pensando…"
        case .error: return "Erro"
        }
    }

    // MARK: Left column

    /// Holds the layout footprint of the sidebar. On a rail tab the footprint stays rail-narrow and the expanded sidebar
    /// floats over the content as a glass overlay, so hovering never pushes the page.
    private var sidebarSlot: some View {
        let full = Theme.Layout.sidebarWidth - padding
        let slot = navCovered ? 0 : (railMode ? Self.railSlot : full)
        let width = railMode && !railExpanded ? Self.railSlot : full
        let compact = railMode && !railExpanded
        return Color.clear
            .frame(width: slot)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                VStack(spacing: 0) {
                    header(compact: compact)
                    leftColumn(compact: compact)
                }
                .padding(.top, titlebarInset)
                .frame(width: width, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .background {
                    if railMode {
                        Color.clear
                            .glass(cornerRadius: Theme.Radius.card)
                            .padding(.top, max(titlebarInset - Theme.Space.s, 0))
                            .padding(.leading, -Theme.Space.s)
                            .padding(.trailing, Theme.Space.xs)
                            .padding(.bottom, -Theme.Space.s)
                            .opacity(railExpanded ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                }
                .onContinuousHover { phase in
                    guard railMode else { return }
                    switch phase {
                    case .active:
                        railHovered = true
                    case .ended:
                        railHovered = false
                    }
                }
                .allowsHitTesting(!navCovered)
            }
            .mask { Rectangle().padding(railMode ? -400 : 0) }
            .opacity(navCovered ? 0 : 1)
            .animation(railAnimation, value: railExpanded)
            .animation(railAnimation, value: railMode)
    }

    private static let slide = Animation.spring(duration: 0.35, bounce: 0.1)

    private func leftColumn(compact: Bool) -> some View {
        SidebarView(controller: controller, model: model, compact: compact)
    }

    // MARK: Tabs

    @ViewBuilder
    private var content: some View {
        if let tab = settingsTab, tab == controller.tab, TabSettings.hasSettings(tab.rawValue) {
            TabSettingsPage(tab: tab, media: media) {
                settingsTab = nil
            } openAll: {
                if let id = TabSettings.fullSection(forTab: tab.rawValue) { SettingsSection(rawValue: id)?.open() }
                controller.tab = .settings
            }
        } else {
            tabContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch controller.tab {
        case .home: home
        case .conversation:
            if model.onboarding.blocksInput {
                OnboardingView(model: model) {
                    SettingsSection.model.open()
                    controller.tab = .settings
                }
            } else {
                ConversationCard(model: model, draft: $draft, submit: submit)
            }
        case .tasks:
            TasksTab(profile: model.profile) { path, line in
                guard let root = model.profile.blocks?.memory?.root else { return }
                BrainModel.shared.openSource(path, line: line, inRoot: root)
                controller.tab = .brain
            }
        case .agenda: AgendaTab(profile: model.profile)
        case .meetings:
            MeetingsTab(model: controller.meetings) { file in
                let root = MeetingLibraryModel.brainRoot()
                if let relative = MemorySearch.relativePath(ofFile: file, inRoot: root) {
                    BrainModel.shared.openSource(relative, line: nil, inRoot: root)
                    controller.tab = .brain
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
                }
            }
        case .brain:
            BrainTab(profile: model.profile) { question, context in
                guard model.send(question, context: context) else { return false }
                controller.tab = .conversation
                return true
            }
        case .music:
            MusicTab(media: media) {
                IntegrationsPane.expandOnOpen = .spotify
                SettingsSection.integrations.open()
                controller.tab = .settings
            }
        case .clipboard: ClipboardView(clipboard: controller.clipboard)
        case .terminal: TerminalTab()
        case .myMac: MyMacTab()
        case .settings: SettingsView(media: media, profile: model.profile)
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Olá, \(Self.firstName)!")
                .font(Theme.Font.heading)
                .foregroundStyle(Theme.textPrimary)
            Text("Escreva para o \(model.personaName)")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 2)
            composer
                .padding(.top, Theme.Space.m)
            HomeDashboard(media: media, model: model) { record in
                if let record { model.open(record) }
                controller.tab = .conversation
            }
            .padding(.top, Theme.Layout.cardGap)
        }
        .padding(.top, Theme.Space.xs)
    }

    private func openModelSettings() {
        SettingsSection.model.open()
        controller.tab = .settings
    }

    private var composer: some View {
        VStack(spacing: 0) {
            composerField
            PendingSetupNote(model: model, openModelSettings: openModelSettings)
        }
    }

    private var composerField: some View {
        ComposerView(
            text: $draft,
            placeholder: "Pergunte ao \(model.personaName)…",
            disabled: model.inputBlocked,
            attachments: model.pendingAttachments,
            notice: model.attachmentNotice,
            onAttach: model.attach,
            onRemove: model.detach,
            onSubmit: submitFromHome
        )
    }

    private func submit() {
        if model.send(draft) { draft = "" }
    }

    private func submitFromHome() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !model.pendingAttachments.isEmpty, !model.inputBlocked else { return }
        if model.currentClosed { model.newConversation() }
        guard model.send(draft) else { return }
        draft = ""
        controller.tab = .conversation
    }

    static let firstName: String = {
        let first = NSFullUserName().split(separator: " ").first.map(String.init)
        return first ?? NSUserName()
    }()
}

private struct ConversationCard: View {
    var model: ConversationViewModel
    @Binding var draft: String
    var submit: () -> Void
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text(model.currentTitle ?? "Nova conversa")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Space.s)
                if let notice = model.telegramNotice {
                    Text(notice)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .help(notice)
                }
                if model.isSharing, model.sharingSession == model.state.sessionId {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                        .help("Compartilhando no Telegram…")
                } else if model.telegram.canShare, model.linkedThread == nil {
                    Button {
                        model.shareCurrent()
                    } label: {
                        Image(systemName: "paperplane")
                    }
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .disabled(!model.canShareCurrent)
                    .help("Compartilhar no Telegram")
                }
                if model.isAwayCurrent {
                    Button {
                        model.returnToMacCurrent()
                    } label: {
                        Image(systemName: "iphone.slash")
                    }
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .help("Voltar ao Mac")
                } else if model.telegram.canShare, model.telegram.canPost, !model.isSharing {
                    Button {
                        model.continueOnPhoneCurrent()
                    } label: {
                        Image(systemName: "iphone")
                    }
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .disabled(!model.canContinueOnPhoneCurrent)
                    .help("Continuar no celular")
                }
                TabSettingsButton(tab: .conversation)
            }
            .frame(height: 26)
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.m)

            ConversationView(model: model)

            if model.currentClosed {
                ClosedBar(model: model)
                    .padding(.bottom, Theme.Space.m)
            } else {
                ComposerView(
                    text: $draft,
                    placeholder: "Pergunte ao \(model.personaName)…",
                    disabled: model.inputBlocked,
                    attachments: model.pendingAttachments,
                    notice: model.attachmentNotice,
                    onAttach: model.attach,
                    onRemove: model.detach,
                    onSubmit: submit
                )
                .padding([.horizontal, .bottom], Theme.Space.m)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !model.inputBlocked, !model.currentClosed else { return false }
            model.attach(files)
            return true
        } isTargeted: { dropping = $0 }
        .card()
    }
}

/// Reports the titlebar height the left column must clear (the traffic lights): 0 in fullscreen, where the titlebar hides
/// and the window already sits below the notch.
private struct TitlebarInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onChange = { value in
            if inset != value { inset = value }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didChangeScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            let full = window.styleMask.contains(.fullScreen)
            onChange?(full ? 0 : max(window.frame.height - window.contentLayoutRect.height, 0))
        }
    }
}
