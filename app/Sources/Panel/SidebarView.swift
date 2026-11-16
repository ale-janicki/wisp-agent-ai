import SwiftUI
import WispCore

struct SidebarView: View {
    @ObservedObject var controller: ShellController
    var model: ConversationViewModel
    var showConversations: () -> Void = {}

    private let sources = TabSources.shared

    private var conversationCount: Int {
        let sections = model.sections
        return sections.wisp.count + sections.telegram.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(PanelTab.nav(for: model.profile)) { tab in
                        navRow(tab)
                    }
                }
            }
            .scrollIndicators(.automatic)

            navRow(.settings)
                .padding(.top, Theme.Space.s)
        }
        .padding(.trailing, Theme.Space.m)
        .padding(.top, Theme.Space.xs)
        .background {
            Button("") {
                model.newConversation()
                controller.tab = .conversation
            }
            .keyboardShortcut("n", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .task(id: model.profile) {
            if !controller.tab.isAvailable(in: model.profile) { controller.tab = .home }
            while !Task.isCancelled {
                sources.refresh(profile: model.profile)
                try? await Task.sleep(for: TabSources.interval)
            }
        }
    }

    private func badge(for tab: PanelTab) -> Int? {
        let count: Int? = switch tab {
        case .conversation: conversationCount
        case .tasks: sources.tasks.openCount
        case .reminders: sources.alertCount
        case .agenda: sources.agenda.remaining
        default: nil
        }
        guard let count, count > 0 else { return nil }
        return count
    }

    private func navRow(_ tab: PanelTab) -> some View {
        let selected = controller.tab == tab
        return Button {
            controller.tab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 18)
                Text(tab.title)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(selected ? Theme.accentText : Theme.textSecondary)
                Spacer(minLength: Theme.Space.xs)
                if let count = badge(for: tab), !(tab == .conversation && selected) {
                    Text("\(count)")
                        .font(Theme.Font.captionMono)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Theme.surfaceHi, in: Capsule())
                }
            }
        }
        .buttonStyle(RowButtonStyle(highlight: selected ? .accent : .none))
        .overlay(alignment: .trailing) {
            if tab == .conversation && selected {
                Button(action: showConversations) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
                .padding(.trailing, Theme.Space.xs)
                .help("Mostrar conversas")
            }
        }
    }
}
