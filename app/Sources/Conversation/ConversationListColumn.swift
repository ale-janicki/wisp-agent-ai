import SwiftUI
import WispCore

struct ConversationListColumn: View {
    @ObservedObject var controller: ShellController
    var model: ConversationViewModel

    private static let refreshInterval: Duration = .seconds(30)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConversationSearchField(text: Bindable(model).searchQuery)
                .padding(.bottom, 2)
            if model.isSearching { results } else { rows }
        }
        .task {
            model.fillPreviews()
            while !Task.isCancelled {
                await model.refreshTelegram()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private var results: some View {
        let hits = model.searchHits
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if hits.isEmpty {
                    Text("Nenhuma conversa encontrada")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, 2)
                }
                ForEach(hits) { hit in
                    switch hit {
                    case .local(let record):
                        ConversationRow(
                            record: record,
                            selected: record.id == model.currentId,
                            preview: model.preview(record),
                            activity: model.activity(id: record.id, sessionId: record.sessionId),
                            canShare: model.canShare(record),
                            away: model.isAway(record),
                            canPhone: model.canContinueOnPhone(record),
                            pinned: model.isPinned(TelegramTopics.pinKey(conversation: record.id)),
                            togglePin: { model.togglePin(TelegramTopics.pinKey(conversation: record.id)) },
                            open: { model.open(record) },
                            share: { model.share(record) },
                            phone: { model.continueOnPhone(record) },
                            backToMac: { model.returnToMac(record) },
                            delete: { model.delete(record) }
                        )
                    case .topic(let entry):
                        TopicRow(
                            entry: entry,
                            selected: model.linkedThread == entry.topic.thread,
                            closing: model.telegram.closing.contains(entry.topic.thread),
                            preview: model.preview(entry),
                            activity: model.activity(id: entry.record?.id, sessionId: entry.topic.sessionId),
                            away: model.isAway(entry),
                            canPhone: model.telegram.canPost && !model.isSharing,
                            pinned: model.isPinned(entry.pinKey),
                            togglePin: { model.togglePin(entry.pinKey) },
                            phone: { model.continueOnPhone(entry) },
                            backToMac: { model.returnToMac(entry) },
                            open: { model.open(entry) },
                            close: { model.close(entry) },
                            blocked: { false }
                        )
                    case .closed(let record):
                        ConversationRow(
                            record: record,
                            selected: record.id == model.currentId,
                            preview: model.preview(record),
                            closed: true,
                            open: { model.open(record) },
                            delete: { model.delete(record) }
                        )
                    }
                }
            }
            .padding(.top, Theme.Space.xs)
        }
        .scrollIndicators(.hidden)
    }

    private var rows: some View {
        let sections = model.sections
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                section("Local") {
                    ForEach(sections.wisp) { record in
                        ConversationRow(
                            record: record,
                            selected: record.id == model.currentId,
                            preview: model.preview(record),
                            activity: model.activity(id: record.id, sessionId: record.sessionId),
                            canShare: model.canShare(record),
                            away: model.isAway(record),
                            canPhone: model.canContinueOnPhone(record),
                            pinned: model.isPinned(TelegramTopics.pinKey(conversation: record.id)),
                            togglePin: { model.togglePin(TelegramTopics.pinKey(conversation: record.id)) },
                            open: { model.open(record) },
                            share: { model.share(record) },
                            phone: { model.continueOnPhone(record) },
                            backToMac: { model.returnToMac(record) },
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

private struct ConversationSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("", text: $text, prompt: Text("Buscar conversa").foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleButtonStyle(size: 20))
                    .help("Limpar busca")
            }
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, 2)
        .frame(height: Theme.Control.compactHeight)
        .background(Capsule().fill(Theme.surfaceHi))
        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        .padding(.horizontal, 2)
    }
}

struct ClosedBar: View {
    var model: ConversationViewModel

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Conversa encerrada — só leitura")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            Button("Reabrir") { model.reopenCurrent() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
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
        case .up: Theme.ok
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

    private var pinnedCount: Int { entries.prefix { model.isPinned($0.pinKey) }.count }

    /// The drag moves a row only inside its own block (pinned or unpinned); the target is clamped to it.
    private var preview: [Int] {
        var ids = entries.map(\.id)
        guard let dragged, let target, let from = ids.firstIndex(of: dragged) else { return ids }
        let block = from < pinnedCount ? 0..<pinnedCount : pinnedCount..<ids.count
        let to = min(max(target, block.lowerBound), block.upperBound - 1)
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
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
                        preview: model.preview(entry),
                        activity: model.activity(id: entry.record?.id, sessionId: entry.topic.sessionId),
                        away: model.isAway(entry),
                        canPhone: model.telegram.canPost && !model.isSharing,
                        pinned: model.isPinned(entry.pinKey),
                        togglePin: { model.togglePin(entry.pinKey) },
                        phone: { model.continueOnPhone(entry) },
                        backToMac: { model.returnToMac(entry) },
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
                    let settings = AppSettings.shared.settings
                    if let result = TelegramTopics.applyDrag(
                        shown: ids, final: final, pinnedCount: pinnedCount,
                        order: settings.telegramOrder, pins: settings.pinnedConversations) {
                        if result.order != settings.telegramOrder { AppSettings.shared.setTelegramOrder(result.order) }
                        if result.pins != settings.pinnedConversations { AppSettings.shared.setPinnedConversations(result.pins) }
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
    var preview: String?
    var activity: RowActivity = .none
    var away = false
    var canPhone = false
    var pinned = false
    var togglePin: () -> Void = {}
    var phone: () -> Void = {}
    var backToMac: () -> Void = {}
    let open: () -> Void
    let close: () -> Void
    let blocked: () -> Bool
    @State private var hovering = false
    @State private var confirming = false

    fileprivate static let height: CGFloat = 52

    var body: some View {
        if confirming {
            VStack(alignment: .leading, spacing: 6) {
                Text("Encerrar «\(entry.topic.name)»?")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Button("Encerrar") {
                        confirming = false
                        close()
                    }
                    .buttonStyle(CapsuleButtonStyle(kind: .accent, size: .compact))
                    Button("Cancelar") { confirming = false }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost, size: .compact))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Self.height)
            .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
        } else {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(entry.topic.name)
                            .font(Theme.Font.body)
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        PinMark(pinned: pinned)
                        ActivityMark(activity: activity)
                        PhoneBadge(away: away)
                    }
                    Text(closing ? "encerrando…" : caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    if let preview {
                        Text(preview)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
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
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .pointerStyle(.default)
                    .padding(.trailing, 6)
                    .help("Encerrar o tópico no Telegram")
                }
            }
            .onHover { hovering = $0 }
            .contextMenu {
                Button(pinned ? "Desafixar" : "Fixar", action: togglePin)
                if away {
                    Button("Voltar ao Mac", action: backToMac)
                } else {
                    Button("Continuar no celular", action: phone)
                        .disabled(!canPhone || closing)
                }
            }
            .help(entry.topic.name)
        }
    }

    private var caption: String {
        let turns = entry.topic.turns == 1 ? "1 turno" : "\(entry.topic.turns) turnos"
        guard let last = entry.topic.lastUsed else { return turns }
        return "\(ConversationRow.relative(last)) · \(turns)"
    }
}

private struct PinMark: View {
    let pinned: Bool

    var body: some View {
        if pinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct PhoneBadge: View {
    let away: Bool

    var body: some View {
        if away {
            Image(systemName: "iphone")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .help("Continuando no celular")
        }
    }
}

private struct ActivityMark: View {
    let activity: RowActivity

    var body: some View {
        switch activity {
        case .none:
            EmptyView()
        case .thinking:
            ProgressView().controlSize(.mini).help("Respondendo…")
        case .attention:
            Circle().fill(Theme.accent).frame(width: 6, height: 6).help("Precisa de atenção")
        case .sharing:
            ProgressView().controlSize(.mini).help("Compartilhando no Telegram…")
        }
    }
}

struct ConversationRow: View {
    let record: ConversationRecord
    let selected: Bool
    var preview: String?
    var activity: RowActivity = .none
    var canShare = false
    var away = false
    var canPhone = false
    var pinned = false
    var togglePin: () -> Void = {}
    var closed = false
    let open: () -> Void
    var share: () -> Void = {}
    var phone: () -> Void = {}
    var backToMac: () -> Void = {}
    let delete: () -> Void
    @State private var hovering = false

    private static let height: CGFloat = 52

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(record.title)
                        .font(Theme.Font.body)
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    PinMark(pinned: pinned)
                    ActivityMark(activity: activity)
                    PhoneBadge(away: away)
                    if closed {
                        Text("encerrada")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(Self.relative(record.updatedAt))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                if let preview {
                    Text(preview)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.trailing, hovering ? 24 : 0)
        }
        .buttonStyle(RowButtonStyle(highlight: selected ? .subtle : .none, height: Self.height, hovered: hovering))
        .overlay(alignment: .trailing) {
            if hovering {
                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                .padding(.trailing, 6)
                .help("Apagar conversa")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if !closed {
                Button(pinned ? "Desafixar" : "Fixar", action: togglePin)
                Button("Compartilhar no Telegram", action: share)
                    .disabled(!canShare)
                if away {
                    Button("Voltar ao Mac", action: backToMac)
                } else {
                    Button("Continuar no celular", action: phone)
                        .disabled(!canPhone)
                }
            }
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
