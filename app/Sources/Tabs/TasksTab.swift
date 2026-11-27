import SwiftUI
import WispCore

struct TasksTab: View {
    let profile: Profile
    var openInBrain: (String, Int?) -> Void = { _, _ in }

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

    private func openSource(_ item: TaskItem) {
        guard let file, !file.isEmpty else { return }
        let url = URL(fileURLWithPath: expandTilde(file))
        let brainRoot = profile.blocks?.memory?.root.flatMap { $0.isEmpty ? nil : $0 }
        Task {
            let text = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
            let line = text.flatMap { TaskList.lineIndex(of: item, in: $0) }
            if let brainRoot, let relative = MemorySearch.relativePath(ofFile: url.path, inRoot: brainRoot) {
                openInBrain(relative, line)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
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
            let shown = TaskList.urgentFirst(TaskList.filter(groups, query: query))
            if shown.isEmpty {
                TabMessage(text: "Nenhuma tarefa com “\(query)”")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { group in
                            if let title = group.title { SectionCaption(text: title) }
                            ForEach(group.items) { item in
                                TaskRow(item: item, busy: tasks.completing == item.id, done: {
                                    if let file { tasks.complete(item, file: file) }
                                }, open: { openSource(item) })
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct TaskRow: View {
    let item: TaskItem
    let busy: Bool
    let done: () -> Void
    let open: () -> Void
    @State private var hovering = false
    @State private var hoveringCheck = false

    private var caption: String {
        [item.front, item.detail.isEmpty ? nil : item.detail].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            if item.urgent {
                Circle()
                    .fill(Theme.error)
                    .frame(width: 8, height: 8)
                    .frame(width: 18)
            }
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
            if busy {
                ProgressView().controlSize(.small).frame(width: 24, height: 24)
            } else {
                ConfirmAction(label: "Apagar tarefa", question: "Apagar?", icon: "trash", action: done)
                Button(action: done) {
                    Image(systemName: hoveringCheck ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(hoveringCheck ? Theme.accent : Theme.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onHover { hoveringCheck = $0 }
                .help("Marcar como feita")
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
        .onTapGesture(perform: open)
        .help([item.title, item.detail].filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}
