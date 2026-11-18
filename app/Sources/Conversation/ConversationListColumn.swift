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
                            held: model.heldDot(record.id),
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
    @State private var dragged: Int?
    @State private var liftedTop: CGFloat = 0
    @State private var grabOffset: CGFloat = 0
    @State private var target: Int?
    @State private var lastDragEnd: Date = .distantPast

    private static let dragThreshold: CGFloat = 6
    private static let reflow = Animation.spring(response: 0.3, dampingFraction: 0.82)
    private static let space = "telegram-rows"
    private static let pitch = TopicRow.height + 2
    private static let clickGuard: TimeInterval = 0.25

    private var telegram: TelegramModel { model.telegram }

    private var dot: Color? {
        switch telegram.link {
        case .notConfigured: nil
        case .checking: Theme.textTertiary
        case .up, .remote: Theme.ok
        case .down: Theme.error
        }
    }

    var body: some View {
        section("Telegram", dot: dot) {
            if telegram.link == .notConfigured {
                connectRow
            } else {
                switch telegram.link {
                case .down(let reason): note("Bot fora: \(reason)")
                case .remote(let host): note("Telegram lido pelo \(host)")
                case .notConfigured, .checking, .up: EmptyView()
                }
                switch telegram.topics {
                case .loading:
                    ForEach(0..<3, id: \.self) { _ in
                        Skeleton(cornerRadius: Theme.Radius.nav).frame(height: 40).padding(.horizontal, 2)
                    }
                case .failed(let reason):
                    note(reason)
                case .loaded:
                    if entries.isEmpty { note("Nenhum tópico aberto") }
                    topicRows
                }
                if let error = telegram.actionError { note(error) }
            }
        }
    }

    private var dragging: Bool { dragged != nil || Date().timeIntervalSince(lastDragEnd) < Self.clickGuard }

    private var preview: [Int] {
        var ids = entries.map(\.id)
        guard let dragged, let target, let from = ids.firstIndex(of: dragged) else { return ids }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target)
        return ids
    }

    private var topicRows: some View {
        let ids = entries.map(\.id)
        let shown = preview
        return ZStack(alignment: .topLeading) {
            if dragged != nil, let target {
                RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
                    .frame(height: TopicRow.height)
                    .offset(y: CGFloat(target) * Self.pitch)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let lifted = entry.id == dragged
                    let slot = CGFloat(shown.firstIndex(of: entry.id) ?? index)
                    let offset = lifted ? liftedTop - CGFloat(index) * Self.pitch : (slot - CGFloat(index)) * Self.pitch
                    TopicRow(
                        entry: entry,
                        selected: model.linkedThread == entry.topic.thread,
                        closing: telegram.closing.contains(entry.topic.thread),
                        held: entry.record.flatMap { model.heldDot($0.id) },
                        open: {
                            guard !dragging else { return }
                            model.open(entry)
                        },
                        close: { model.close(entry) },
                        blocked: { dragging }
                    )
                    .scaleEffect(lifted ? 1.02 : 1)
                    .shadow(color: Theme.notch.opacity(lifted ? 0.45 : 0), radius: lifted ? 14 : 0, y: lifted ? 6 : 0)
                    .offset(y: offset)
                    .zIndex(lifted ? 1 : 0)
                    .pointerStyle(lifted ? .grabActive : .grabIdle)
                    .animation(lifted ? nil : Self.reflow, value: offset)
                    .simultaneousGesture(reorder(entry.id, ids: ids))
                }
            }
        }
        .coordinateSpace(.named(Self.space))
        .onChange(of: ids) { _, now in
            if let dragged, !now.contains(dragged) {
                self.dragged = nil
                target = nil
            }
        }
    }

    private func reorder(_ id: Int, ids: [Int]) -> some Gesture {
        DragGesture(minimumDistance: Self.dragThreshold, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragged == nil, let index = ids.firstIndex(of: id) {
                    grabOffset = value.startLocation.y - CGFloat(index) * Self.pitch
                    dragged = id
                    target = index
                }
                guard dragged == id else { return }
                liftedTop = value.location.y - grabOffset
                let slot = min(max(Int(((liftedTop + TopicRow.height / 2) / Self.pitch).rounded(.down)), 0), ids.count - 1)
                if slot != target { withAnimation(Self.reflow) { target = slot } }
            }
            .onEnded { _ in
                guard dragged == id else { return }
                let final = preview
                lastDragEnd = Date()
                withAnimation(Self.reflow) {
                    if final != ids {
                        let saved = AppSettings.shared.settings.telegramOrder
                        AppSettings.shared.setTelegramOrder(final + saved.filter { !final.contains($0) })
                    }
                    dragged = nil
                    target = nil
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
    let held: StatusColor?
    let open: () -> Void
    let close: () -> Void
    let blocked: () -> Bool
    @State private var hovering = false
    @State private var confirming = false

    fileprivate static let height: CGFloat = 44

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
                    HStack(spacing: 6) {
                        if let held { HeldDot(color: held) }
                        Text(entry.topic.name)
                            .font(Theme.Font.body)
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(closing ? "encerrando…" : caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                .padding(.trailing, (hovering && !entry.topic.fixed) || closing ? 24 : 0)
            }
            .buttonStyle(RowButtonStyle(highlight: selected ? .subtle : .none, height: Self.height, hovered: hovering))
            .overlay(alignment: .trailing) {
                if closing {
                    ProgressView().controlSize(.small).padding(.trailing, 10)
                } else if hovering && !entry.topic.fixed {
                    Button {
                        guard !blocked() else { return }
                        confirming = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(CircleButtonStyle(size: 24))
                    .pointerStyle(.default)
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
    let held: StatusColor?
    let open: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    private static let height: CGFloat = 44

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let held { HeldDot(color: held) }
                    Text(record.title)
                        .font(Theme.Font.body)
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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

/// A conversation with messages in the outbox: amber while they wait, red when one was not sent.
private struct HeldDot: View {
    let color: StatusColor

    var body: some View {
        Circle()
            .fill(color.color)
            .frame(width: 6, height: 6)
            .help(color == .error ? "Uma mensagem não foi enviada" : "Mensagens na fila do Telegram")
    }
}
