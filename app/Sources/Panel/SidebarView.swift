import SwiftUI
import WispCore

struct SidebarView: View {
    @ObservedObject var controller: ShellController
    var model: ConversationViewModel
    var showConversations: () -> Void = {}

    @ObservedObject private var meetings: MeetingRecordingModel
    private let sources = TabSources.shared

    init(controller: ShellController, model: ConversationViewModel, showConversations: @escaping () -> Void = {}) {
        self.controller = controller
        self.model = model
        self.showConversations = showConversations
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

            recordingRow
                .padding(.top, Theme.Space.s)
            navRow(.settings)
                .padding(.top, 2)
        }
        .padding(.trailing, Theme.Space.m)
        .padding(.top, Theme.Space.xs)
        .background {
            Button("") {
                model.newConversation()
                controller.tab = .conversation
                showConversations()
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

    private var recordingTitle: String {
        switch meetings.phase {
        case .idle: "Gravar reunião"
        case .starting: "Iniciando…"
        case .recording: "Parar gravação"
        case .finishing: "Salvando…"
        }
    }

    private var recordingRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                meetings.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: meetings.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(meetings.isRecording ? Theme.error : Theme.textSecondary)
                        .frame(width: 18)
                    Text(recordingTitle)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(meetings.isRecording ? Theme.error : Theme.textSecondary)
                    Spacer(minLength: Theme.Space.xs)
                    if let startedAt = meetings.startedAt {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(ElapsedFormat.clock(context.date.timeIntervalSince(startedAt)))
                                .font(Theme.Font.captionMono)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .buttonStyle(RowButtonStyle(highlight: meetings.isRecording ? .accent : .none))
            .disabled(meetings.isBusy)
            .help("Grava o microfone e o áudio do Mac (a outra ponta da call). Só grava quando você clica.")
            ForEach(meetings.warnings, id: \.self) { warning in
                Text(warning)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.busy)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.s)
            }
            if let message = meetings.message {
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.s)
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
        let listHint = tab == .conversation && selected
        return Button {
            if listHint { showConversations() } else { controller.tab = tab }
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
                if listHint {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                if let count = badge(for: tab), !listHint {
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
        .help(listHint ? "Mostrar conversas" : "")
    }
}
