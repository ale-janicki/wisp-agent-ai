import SwiftUI
import WispCore

struct HomeDashboard: View {
    @ObservedObject var media: NowPlayingService
    var model: ConversationViewModel
    var openConversation: (ConversationRecord?) -> Void

    private let dashboard = Dashboard.shared
    private let settings = AppSettings.shared
    private var gap: CGFloat { Theme.Layout.cardGap }
    private var alertsCommand: String? {
        guard let command = model.profile.blocks?.alerts?.list, !command.isEmpty else { return nil }
        return command
    }

    private static let dragThreshold: CGFloat = 6
    private static let reflow = Animation.spring(response: 0.3, dampingFraction: 0.82)
    private static let space = "dashboard-grid"

    @State private var dragged: String?
    @State private var pointer: CGPoint = .zero
    @State private var grabOffset: CGSize = .zero
    @State private var target: Int?

    private var visible: [String] {
        settings.settings.dashboardOrder.filter { $0 != DashboardTileID.alerts || alertsCommand != nil }
    }

    private var preview: [String] {
        var ids = visible
        guard let dragged, let target, let from = ids.firstIndex(of: dragged) else { return ids }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target)
        return ids
    }

    var body: some View {
        GeometryReader { geo in
            let ids = visible
            let slots = Self.slots(count: ids.count, in: geo.size, gap: gap)
            ZStack(alignment: .topLeading) {
                if dragged != nil, let target, slots.indices.contains(target) {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 1.5)
                        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .frame(width: slots[target].width, height: slots[target].height)
                        .offset(x: slots[target].minX, y: slots[target].minY)
                        .allowsHitTesting(false)
                }
                ForEach(ids, id: \.self) { id in
                    let lifted = id == dragged
                    let slot = slots[preview.firstIndex(of: id) ?? 0]
                    let origin = slots[ids.firstIndex(of: id) ?? 0]
                    let frame = lifted ? CGRect(origin: CGPoint(x: pointer.x - grabOffset.width, y: pointer.y - grabOffset.height), size: origin.size) : slot
                    tile(id)
                        .frame(width: frame.width, height: frame.height)
                        .scaleEffect(lifted ? 1.02 : 1)
                        .shadow(color: Theme.notch.opacity(lifted ? 0.45 : 0), radius: lifted ? 14 : 0, y: lifted ? 6 : 0)
                        .offset(x: frame.minX, y: frame.minY)
                        .zIndex(lifted ? 1 : 0)
                        .pointerStyle(lifted ? .grabActive : nil)
                        .animation(lifted ? nil : Self.reflow, value: frame)
                        .simultaneousGesture(reorder(id, slots: slots, ids: ids))
                }
            }
            .coordinateSpace(.named(Self.space))
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .onAppear { dashboard.usage.refreshIfStale() }
        .task(id: alertsCommand) {
            guard let alertsCommand else { return }
            while !Task.isCancelled {
                dashboard.alerts.refresh(command: alertsCommand)
                try? await Task.sleep(for: AlertsModel.interval)
            }
        }
    }

    @ViewBuilder
    private func tile(_ id: String) -> some View {
        switch id {
        case DashboardTileID.music:
            DashboardTile(title: "Música", icon: "music.note", trailing: media.player?.name) {
                MediaCardView(media: media, style: .tile)
            }
        case DashboardTileID.usage:
            UsageTile(usage: dashboard.usage, rateLimit: model.rateLimit, limitsPath: model.profile.blocks?.usage?.limits)
        case DashboardTileID.alerts:
            if let alertsCommand {
                AlertsTile(alerts: dashboard.alerts, command: alertsCommand)
            }
        default:
            LastConversationTile(model: model, preview: dashboard.lastConversation, open: openConversation)
        }
    }

    private func reorder(_ id: String, slots: [CGRect], ids: [String]) -> some Gesture {
        DragGesture(minimumDistance: Self.dragThreshold, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragged == nil, let index = ids.firstIndex(of: id) {
                    let origin = slots[index]
                    grabOffset = CGSize(width: value.startLocation.x - origin.minX, height: value.startLocation.y - origin.minY)
                    dragged = id
                    target = index
                }
                guard dragged == id else { return }
                pointer = value.location
                let slot = Self.slot(at: value.location, in: slots)
                if slot != target { withAnimation(Self.reflow) { target = slot } }
            }
            .onEnded { _ in
                guard dragged == id else { return }
                let final = preview
                withAnimation(Self.reflow) {
                    if final != ids { settings.setDashboardOrder(final) }
                    dragged = nil
                    target = nil
                }
            }
    }

    static func slots(count: Int, in size: CGSize, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let rows = (count + 1) / 2
        let width = (size.width - gap) / 2
        let height = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return (0..<count).map { index in
            let row = index / 2, column = index % 2
            let spans = index == count - 1 && count % 2 == 1
            return CGRect(
                x: spans || column == 0 ? 0 : width + gap,
                y: CGFloat(row) * (height + gap),
                width: spans ? size.width : width,
                height: height
            )
        }
    }

    static func slot(at point: CGPoint, in slots: [CGRect]) -> Int? {
        if let hit = slots.firstIndex(where: { $0.contains(point) }) { return hit }
        return slots.indices.min { distance(point, slots[$0]) < distance(point, slots[$1]) }
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        hypot(point.x - rect.midX, point.y - rect.midY)
    }
}

struct DashboardTile<Content: View>: View {
    let title: String
    let icon: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16)
                Text(title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                if let trailing {
                    Text(trailing)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .pointerStyle(.grabIdle)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

// MARK: - Uso do Claude

private struct UsageTile: View {
    var usage: UsageModel
    var rateLimit: RateLimit?
    var limitsPath: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let limits = usage.limits
            DashboardTile(title: "Uso do Claude", icon: "chart.bar.fill", trailing: limits.map { PlanLimitsSnapshot.age(of: $0.capturedAt, now: context.date) }) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let limits {
                        ForEach(limits.rows(now: context.date), id: \.kind) { row in
                            PlanLimitBar(row: row)
                        }
                    } else {
                        Text("Abra o Claude Code para ler o limite")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let summary = usage.summary {
                        Text("Hoje \(UsageFormat.tokens(summary.today.billableTokens)) tokens · 7 dias \(UsageFormat.tokens(summary.billableTokens))")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .task(id: limitsPath) {
            while !Task.isCancelled {
                usage.reloadLimits(path: limitsPath)
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: rateLimit) { _, limit in usage.noteOwn(limit) }
    }
}

private struct PlanLimitBar: View {
    let row: PlanLimitRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(label)
                    .font(Theme.Font.captionMono)
                    .foregroundStyle(Theme.textSecondary)
                if let detail {
                    Text("· \(detail)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            Capsule()
                .fill(Theme.stroke)
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(color)
                            .frame(width: geo.size.width * fraction)
                    }
                }
        }
    }

    private var name: String { row.kind == .session ? "Sessão" : "Semana" }

    private var label: String {
        switch row.state {
        case .used(let percent, _, _): "\(name) \(percent)%"
        case .renewed: "\(name) renovado"
        }
    }

    private var detail: String? {
        guard case .used(_, let resetsAt?, _) = row.state else { return nil }
        return "renova " + (row.kind == .session ? Self.time(resetsAt) : Self.dayTime(resetsAt))
    }

    private var fraction: CGFloat {
        guard case .used(let percent, _, _) = row.state else { return 0 }
        return CGFloat(min(max(percent, 0), 100)) / 100
    }

    private var color: Color {
        guard case .used(_, _, let severity) = row.state else { return Theme.accent }
        switch severity {
        case .normal: return Theme.accent
        case .warning: return Theme.busy
        case .critical: return Theme.error
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "pt_BR")))
    }

    private static func dayTime(_ date: Date) -> String {
        let day = date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "pt_BR"))).replacingOccurrences(of: ".", with: "")
        return "\(day) \(time(date))"
    }
}

// MARK: - Notificações

private struct AlertsTile: View {
    var alerts: AlertsModel
    let command: String

    private var trailing: String? {
        if case .loaded(let items) = alerts.state, !items.isEmpty { return "\(items.count)" }
        return nil
    }

    var body: some View {
        DashboardTile(title: "Notificações", icon: "bell.fill", trailing: trailing) {
            switch alerts.state {
            case .loading:
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(0..<3, id: \.self) { _ in Skeleton(cornerRadius: 6).frame(height: 16) }
                }
            case .loaded(let items) where items.isEmpty:
                centered("Nenhum alerta")
            case .loaded(let items):
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { AlertRow(item: $0) }
                    }
                }
                .scrollIndicators(.hidden)
            case .failed(let message):
                centered(message)
            }
        }
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AlertRow: View {
    let item: AlertItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Circle()
                .fill(item.level == .red ? Theme.error : Theme.busy)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(item.text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Space.xs)
            if let opened = item.openedAt {
                Text(AlertList.age(of: opened))
                    .font(Theme.Font.captionMono)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .help(item.text)
    }
}

// MARK: - Última conversa

private struct LastConversationTile: View {
    var model: ConversationViewModel
    var preview: LastConversationModel
    var open: (ConversationRecord?) -> Void
    @State private var hovering = false

    private static let shown = 3

    private var current: [ConversationMessage] {
        model.state.messages.filter { $0.role == .user || $0.role == .assistant }
    }

    private var usesPreview: Bool { current.isEmpty && model.currentTitle == nil }

    private var messages: [ConversationMessage] {
        let source = usesPreview ? preview.messages.filter { $0.role == .user || $0.role == .assistant } : current
        return Array(source.suffix(Self.shown))
    }

    private var title: String? {
        usesPreview ? preview.record?.title : model.currentTitle
    }

    var body: some View {
        DashboardTile(title: "Última conversa", icon: "bubble.left.and.bubble.right.fill", trailing: title) {
            Group {
                if usesPreview, preview.loading {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack { Spacer(); Skeleton(cornerRadius: Theme.Radius.bubble).frame(width: 140, height: 28) }
                        Skeleton(cornerRadius: Theme.Radius.bubble).frame(width: 200, height: 28)
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                } else if messages.isEmpty {
                    Text("Nenhuma conversa ainda")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let shown = messages
                    GeometryReader { geo in
                        ViewThatFits(in: .vertical) {
                            ForEach(Array(stride(from: shown.count, to: 0, by: -1)), id: \.self) { count in
                                bubbles(Array(shown.suffix(count)), width: geo.size.width)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                    }
                    .clipped()
                    .allowsHitTesting(false)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(hovering ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture { open(usesPreview ? preview.record : nil) }
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help("Abrir em Conversa")
        .onAppear(perform: loadPreview)
        .onChange(of: model.records) { _, _ in loadPreview() }
    }

    private func bubbles(_ shown: [ConversationMessage], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { message in
                MessageRow(message: message, maxWidth: width * 0.85, lineLimit: 2)
            }
        }
    }

    private func loadPreview() {
        preview.load(model.records.first, cwd: expandTilde(model.profile.agent.cwd), statusPrefix: model.profile.agent.statusPrefix)
    }
}
