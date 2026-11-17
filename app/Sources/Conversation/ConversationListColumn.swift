import SwiftUI
import WispCore

struct ConversationListColumn: View {
    @ObservedObject var controller: ShellController
    var model: ConversationViewModel
    var showNav: () -> Void

    private static let refreshInterval: Duration = .seconds(30)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Button(action: showNav) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(RowButtonStyle())
                .help("Mostrar menu")
            }
            .padding(.top, Theme.Space.xs)
            rows
        }
        .task {
            while !Task.isCancelled {
                await model.refreshTelegram()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private var rows: some View {
        let sections = model.sections
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                section("Wisp") {
                    ForEach(sections.wisp) { record in
                        ConversationRow(
                            record: record,
                            selected: record.id == model.currentId,
                            open: { model.open(record) },
                            delete: { model.delete(record) }
                        )
                    }
                    Button {
                        model.newConversation()
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 18)
                            Text("Nova")
                                .font(Theme.Font.body)
                        }
                        .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(RowButtonStyle())
                    .help("Nova conversa (⌘N)")
                }
                TelegramSection(model: model, entries: sections.telegram)
                    .padding(.top, Theme.Space.m)
            }
            .padding(.top, Theme.Space.xs)
        }
        .scrollIndicators(.hidden)
    }
}

@MainActor
private func section<Rows: View>(_ title: String, dot: Color? = nil, @ViewBuilder rows: () -> Rows) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
        }
        .padding(.leading, Theme.Space.m)
        .padding(.bottom, 4)
        rows()
    }
}

private struct TelegramSection: View {
    var model: ConversationViewModel
    let entries: [TelegramEntry]
    @State private var explaining = false

    private var telegram: TelegramModel { model.telegram }

    private var dot: Color? {
        switch telegram.link {
        case .notConfigured: nil
        case .checking: Theme.textTertiary
        case .up: Theme.ok
        case .down: Theme.error
        }
    }

    var body: some View {
        section("Telegram", dot: dot) {
            if telegram.link == .notConfigured {
                connectRow
            } else {
                if case .down(let reason) = telegram.link { note("Bot fora: \(reason)") }
                switch telegram.topics {
                case .loading:
                    ForEach(0..<3, id: \.self) { _ in
                        Skeleton(cornerRadius: Theme.Radius.nav).frame(height: 40).padding(.horizontal, 2)
                    }
                case .failed(let reason):
                    note(reason)
                case .loaded:
                    if entries.isEmpty { note("Nenhum tópico aberto") }
                    ForEach(entries) { entry in
                        TopicRow(
                            entry: entry,
                            selected: model.linkedThread == entry.topic.thread,
                            closing: telegram.closing.contains(entry.topic.thread),
                            open: { model.open(entry) },
                            close: { model.close(entry) }
                        )
                    }
                }
                if let error = telegram.actionError { note(error) }
            }
        }
    }

    private var connectRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { explaining.toggle() } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18)
                    Text("Conectar Telegram")
                        .font(Theme.Font.body)
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(RowButtonStyle())
            if explaining { note("O setup do Wisp conecta o bot do Telegram; ele chega no Plano 2.") }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 2)
    }
}

private struct TopicRow: View {
    let entry: TelegramEntry
    let selected: Bool
    let closing: Bool
    let open: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var confirming = false

    private static let height: CGFloat = 44

    var body: some View {
        if confirming {
            HStack(spacing: 6) {
                Text("Encerrar no Telegram?")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Sim") {
                    confirming = false
                    close()
                }
                .buttonStyle(CompactCapsuleStyle(accent: true))
                Button("Não") { confirming = false }
                    .buttonStyle(CompactCapsuleStyle(accent: false))
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Self.height)
            .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
        } else {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.topic.name)
                        .font(Theme.Font.body)
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(closing ? "encerrando…" : caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                .padding(.trailing, hovering || closing ? 24 : 0)
            }
            .buttonStyle(RowButtonStyle(highlight: selected ? .subtle : .none, height: Self.height, hovered: hovering))
            .overlay(alignment: .trailing) {
                if closing {
                    ProgressView().controlSize(.small).padding(.trailing, 10)
                } else if hovering {
                    Button { confirming = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(CircleButtonStyle(size: 24))
                    .padding(.trailing, 6)
                    .help("Encerrar o tópico no Telegram")
                }
            }
            .onHover { hovering = $0 }
            .help(entry.topic.name)
        }
    }

    private var caption: String {
        let turns = entry.topic.turns == 1 ? "1 turno" : "\(entry.topic.turns) turnos"
        guard let last = entry.topic.lastUsed else { return turns }
        return "\(ConversationRow.relative(last)) · \(turns)"
    }
}

private struct ConversationRow: View {
    let record: ConversationRecord
    let selected: Bool
    let open: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    private static let height: CGFloat = 44

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title)
                    .font(Theme.Font.body)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.relative(record.updatedAt))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.trailing, hovering ? 24 : 0)
        }
        .buttonStyle(RowButtonStyle(highlight: selected ? .subtle : .none, height: Self.height, hovered: hovering))
        .overlay(alignment: .trailing) {
            if hovering {
                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(CircleButtonStyle(size: 24))
                .padding(.trailing, 6)
                .help("Apagar conversa")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Apagar conversa", role: .destructive, action: delete)
        }
        .help(record.title)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let locale = Locale(identifier: "pt_BR")
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
        if calendar.isDate(date, inSameDayAs: now) { return "hoje, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "ontem, \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated).locale(locale))), \(time)"
    }
}
