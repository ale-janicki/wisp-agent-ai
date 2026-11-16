import AppKit
import SwiftUI
import WispCore

struct PanelView: View {
    @ObservedObject var controller: ShellController
    @ObservedObject var media: NowPlayingService
    var model: ConversationViewModel
    @State private var draft = ""

    private static let headerHeight: CGFloat = 56

    private var padding: CGFloat { Theme.Layout.panelPadding }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.profileError != nil || model.onboarding != nil {
                OnboardingView(model: model)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    SidebarView(controller: controller, model: model)
                        .frame(width: Theme.Layout.sidebarWidth - padding)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
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

    // MARK: Tabs

    @ViewBuilder
    private var content: some View {
        switch controller.tab {
        case .home: home
        case .conversation:
            HStack(alignment: .top, spacing: Theme.Layout.cardGap) {
                ConversationListColumn(controller: controller, model: model)
                ConversationCard(model: model, draft: $draft, submit: submit)
            }
        case .tasks: TasksTab(profile: model.profile)
        case .reminders: RemindersTab(profile: model.profile)
        case .agenda: AgendaTab(profile: model.profile)
        case .memory: MemoryTab(profile: model.profile)
        case .routines: RoutinesTab(profile: model.profile)
        case .timers: TimersView(timers: controller.timers)
        case .music: MediaCardView(media: media, style: .large)
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
                }
            }
            .frame(height: 26)
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.m)

            ConversationView(model: model)

            ComposerView(
                text: $draft,
                placeholder: "Pergunte ao \(model.personaName)…",
                disabled: model.inputBlocked,
                onSubmit: submit
            )
            .padding([.horizontal, .bottom], Theme.Space.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .card()
    }
}
