import AppKit
import SwiftUI
import WispCore

struct PanelView: View {
    @ObservedObject var controller: ShellController
    @ObservedObject var media: NowPlayingService
    var model: ConversationViewModel
    @State private var draft = ""
    @State private var listShown: Bool
    @State private var settingsTab: PanelTab?
    @State private var navCovered = false

    #if DEBUG
    nonisolated(unsafe) static var snapshotNav = false
    #endif

    init(controller: ShellController, media: NowPlayingService, model: ConversationViewModel) {
        self.controller = controller
        self.media = media
        self.model = model
        #if DEBUG
        let navHidden = Self.snapshotNav
        #else
        let navHidden = false
        #endif
        _listShown = State(initialValue: controller.tab == .conversation && !navHidden)
    }

    private static let headerHeight: CGFloat = 56

    private var padding: CGFloat { Theme.Layout.panelPadding }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.profileError != nil || model.onboarding != nil {
                OnboardingView(model: model)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    leftColumn
                        .frame(width: navCovered ? 0 : Theme.Layout.sidebarWidth - padding)
                        .clipped()
                        .allowsHitTesting(!navCovered)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .environment(\.openTabSettings) { settingsTab = $0 }
        .environment(\.navCover, NavCover(isCovered: navCovered) { covered in
            withAnimation(Self.slide) { navCovered = covered }
        })
        .onChange(of: controller.tab) { _, tab in
            settingsTab = nil
            if tab != .meetings { navCovered = false }
        }
        .padding(.horizontal, padding)
        .padding(.bottom, padding)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                WispAvatar(size: 36, busy: controller.statusColor == .busy, imagePath: model.profile.persona.avatar)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.personaName)
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusLabel)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: controller.notchWidth + 2 * Theme.Space.xl)

            Text(model.state.status ?? "")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: Self.headerHeight)
        .padding(.top, 2)
    }

    private var statusColor: Color {
        model.inputBlocked ? Theme.busy : controller.statusColor.color
    }

    private var statusLabel: String {
        if model.inputBlocked { return "Configuração pendente" }
        switch controller.statusColor {
        case .ok: return "Pronto"
        case .busy: return "Pensando…"
        case .error: return "Erro"
        }
    }

    // MARK: Left column

    private static let slide = Animation.spring(duration: 0.35, bounce: 0.1)

    private var leftColumn: some View {
        ZStack(alignment: .topLeading) {
            SidebarView(controller: controller, model: model) { setList(true) }
            if listShown {
                ConversationListColumn(controller: controller, model: model) { setList(false) }
                    .padding(.trailing, Theme.Space.m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.bg)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .onChange(of: controller.tab) { _, tab in
            setList(tab == .conversation)
        }
    }

    private func setList(_ shown: Bool) {
        withAnimation(Self.slide) { listShown = shown }
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
            ConversationCard(model: model, draft: $draft, submit: submit)
        case .tasks: TasksTab(profile: model.profile)
        case .reminders: RemindersTab(profile: model.profile)
        case .agenda: AgendaTab(profile: model.profile)
        case .meetings: MeetingsTab(model: controller.meetings)
        case .brain:
            BrainTab(profile: model.profile) { question, context in
                guard model.send(question, context: context) else { return false }
                controller.tab = .conversation
                return true
            }
        case .routines: RoutinesTab(profile: model.profile)
        case .music:
            MusicTab(media: media) {
                IntegrationsPane.expandOnOpen = .spotify
                SettingsSection.integrations.open()
                controller.tab = .settings
            }
        case .clipboard: ClipboardView(clipboard: controller.clipboard)
        case .myMac: MyMacTab()
        case .settings: SettingsView(media: media)
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

    private var composer: some View {
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
    }

    private func submit() {
        if model.send(draft) { draft = "" }
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
            guard !files.isEmpty, !model.inputBlocked else { return false }
            model.attach(files)
            return true
        } isTargeted: { dropping = $0 }
        .card()
    }
}
