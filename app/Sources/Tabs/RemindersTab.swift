import SwiftUI
import WispCore

struct RemindersTab: View {
    let profile: Profile

    private var alerts: AlertsModel { TabSources.shared.alerts }
    private var listCommand: String? { profile.blocks?.alerts?.list }
    private var resolveCommand: String? {
        guard let command = profile.blocks?.alerts?.resolve, !command.isEmpty else { return nil }
        return command
    }

    private var trailing: String? {
        guard case .loaded(let items) = alerts.state, !items.isEmpty else { return nil }
        return items.count == 1 ? "1 aberto" : "\(items.count) abertos"
    }

    var body: some View {
        TabCard(title: "Lembretes", icon: PanelTab.reminders.icon, trailing: trailing) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let error = alerts.actionError { InlineError(text: error) }
                list
            }
        }
        .onAppear { if let listCommand { alerts.refresh(command: listCommand) } }
    }

    @ViewBuilder
    private var list: some View {
        switch alerts.state {
        case .loading:
            SkeletonRows(count: 3)
        case .failed(let message):
            TabMessage(text: message)
        case .loaded(let items) where items.isEmpty:
            TabMessage(text: "Nenhum alerta aberto")
        case .loaded(let items):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        ReminderRow(item: item, busy: alerts.resolving == item.id, resolve: action(for: item))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func action(for item: AlertItem) -> (() -> Void)? {
        guard let resolveCommand, let listCommand else { return nil }
        return { alerts.resolve(item, template: resolveCommand, listCommand: listCommand) }
    }
}

private struct ReminderRow: View {
    let item: AlertItem
    let busy: Bool
    let resolve: (() -> Void)?
    @State private var hovering = false

    private var caption: String {
        var parts = [item.front, item.theme == item.id ? nil : item.theme].compactMap { $0 }
        if let opened = item.openedAt { parts.append("há \(AlertList.age(of: opened))") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Circle()
                .fill(item.level == .red ? Theme.error : Theme.busy)
                .frame(width: 8, height: 8)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if !caption.isEmpty {
                    Text(caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            if let resolve, hovering || busy {
                ConfirmAction(label: "Resolver", question: "Resolver?", busy: busy, action: resolve)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous)
                .fill(hovering ? Theme.surfaceHi.opacity(0.7) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
        .onHover { hovering = $0 }
        .help("\(item.text)\n\(item.id)")
    }
}
