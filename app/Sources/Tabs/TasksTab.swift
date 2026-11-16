import SwiftUI
import WispCore

struct TasksTab: View {
    let profile: Profile

    private var tasks: TasksModel { TabSources.shared.tasks }
    private var file: String? { profile.blocks?.tasks?.file }
    @State private var query = ""

    var body: some View {
        TabCard(title: "Tarefas", icon: PanelTab.tasks.icon, trailing: tasks.openCount.map { "\($0) em aberto" }) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SearchField(text: $query, placeholder: "Buscar tarefas")
                if let error = tasks.actionError { InlineError(text: error) }
                list
            }
        }
        .onAppear { if let file { tasks.refresh(file: file) } }
    }

    @ViewBuilder
    private var list: some View {
        switch tasks.state {
        case .loading:
            SkeletonRows()
        case .failed(let message):
            TabMessage(text: message)
        case .loaded(let groups) where groups.isEmpty:
            TabMessage(text: "Nada em aberto")
        case .loaded(let groups):
            let shown = TaskList.filter(groups, query: query)
            if shown.isEmpty {
                TabMessage(text: "Nenhuma tarefa com “\(query)”")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { group in
                            if let title = group.title { SectionCaption(text: title) }
                            ForEach(group.items) { item in
                                TaskRow(item: item, busy: tasks.completing == item.id) {
                                    if let file { tasks.complete(item, file: file) }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }
}

private struct TaskRow: View {
    let item: TaskItem
    let busy: Bool
    let done: () -> Void
    @State private var hovering = false

    private var caption: String {
        [item.front, item.detail.isEmpty ? nil : item.detail].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let owner = item.owner {
                        Text(owner)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Theme.accentFill, in: Capsule())
                    }
                    Text(item.title)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !caption.isEmpty {
                    Text(caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            if hovering || busy {
                ConfirmAction(label: "Feito", question: "Apagar a linha?", busy: busy, action: done)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous)
                .fill(hovering ? Theme.surfaceHi.opacity(0.7) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
        .onHover { hovering = $0 }
        .help(TaskList.plain(String(item.line.dropFirst(2))))
    }
}
