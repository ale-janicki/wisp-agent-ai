import SwiftUI
import WispCore

struct SidebarView: View {
    @ObservedObject var controller: ShellController
    var model: ConversationViewModel
    var compact = false

    @ObservedObject private var meetings: MeetingRecordingModel
    private let sources = TabSources.shared

    init(controller: ShellController, model: ConversationViewModel, compact: Bool = false) {
        self.controller = controller
        self.model = model
        self.compact = compact
        _meetings = ObservedObject(wrappedValue: controller.meetings)
    }

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
            .scrollIndicators(.hidden)

            navRow(.settings)
                .padding(.top, Theme.Space.s)
        }
        .padding(.trailing, compact ? Theme.Space.s + 2 : Theme.Space.m)
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
                    .overlay(alignment: .topTrailing) {
                        if compact, tab != .settings { compactMark(for: tab) }
                    }
                if !compact {
                    Text(tab.title)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(selected ? Theme.accentText : Theme.textSecondary)
                    Spacer(minLength: Theme.Space.xs)
                    if tab == .meetings, meetings.startedAt != nil {
                        RecordingDot(warns: !meetings.warnings.isEmpty, paused: meetings.isPaused)
                            .help(meetings.isPaused ? "Gravação pausada" : "Gravando")
                    }
                    if let count = badge(for: tab) {
                        Text("\(count)")
                            .font(Theme.Font.captionMono)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Theme.surfaceHi, in: Capsule())
                    }
                }
            }
        }
        .buttonStyle(RowButtonStyle(highlight: selected ? .accent : .none))
        .help(compact ? tab.title : "")
    }

    /// Rail only: a recording shows its dot, a count shows as a small accent dot on the icon corner.
    @ViewBuilder
    private func compactMark(for tab: PanelTab) -> some View {
        if tab == .meetings, meetings.startedAt != nil {
            RecordingDot(warns: !meetings.warnings.isEmpty, paused: meetings.isPaused)
                .offset(x: 5, y: -4)
        } else if badge(for: tab) != nil {
            Circle()
                .fill(Theme.accent)
                .frame(width: 7, height: 7)
                .offset(x: 5, y: -4)
        }
    }
}
