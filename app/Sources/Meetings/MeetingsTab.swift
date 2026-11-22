import AppKit
import SwiftUI
import WispCore

struct NavCover {
    var isCovered = false
    var set: (Bool) -> Void = { _ in }
}

private struct NavCoverKey: EnvironmentKey {
    static var defaultValue: NavCover { NavCover() }
}

extension EnvironmentValues {
    var navCover: NavCover {
        get { self[NavCoverKey.self] }
        set { self[NavCoverKey.self] = newValue }
    }
}

struct MeetingsTab: View {
    @Environment(\.navCover) private var navCover
    @ObservedObject var model: MeetingRecordingModel
    @ObservedObject private var library: MeetingLibraryModel
    @ObservedObject private var speech: SpeechModelModel

    private let openInBrain: (String) -> Void

    init(model: MeetingRecordingModel, openInBrain: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.openInBrain = openInBrain
        _library = ObservedObject(wrappedValue: model.library)
        _speech = ObservedObject(wrappedValue: model.speech)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Layout.cardGap) {
            MeetingListCard(model: model, library: library)
                .frame(width: 250)
            MeetingMainCard(model: model, library: library, speech: speech)
        }
        .onAppear {
            library.openInBrain = openInBrain
            model.refreshPermissions()
            speech.refresh()
            library.reload(thenProcess: true)
            navCover.set(library.selectedID != nil)
        }
        .onChange(of: library.selectedID) { _, id in
            navCover.set(id != nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}

private struct MeetingListCard: View {
    @ObservedObject var model: MeetingRecordingModel
    @ObservedObject var library: MeetingLibraryModel

    var body: some View {
        TabCard(title: "Reuniões", icon: "waveform", trailing: library.entries.isEmpty ? nil : "\(library.entries.count)", settingsTab: .meetings) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                RecorderBar(model: model)
                    .padding(.bottom, Theme.Space.xs)
                if model.phase != .idle {
                    liveRow
                }
                if library.isLoading {
                    SkeletonRows()
                } else if library.rows.isEmpty {
                    TabMessage(text: "Nenhuma reunião ainda.\nGrave a primeira acima.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(library.rows) { row in
                                MeetingRow(row: row, selected: library.selectedID == row.id, stage: library.stage(of: row.id)) {
                                    library.select(row.id)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private var liveRow: some View {
        Button {
            library.select(nil)
        } label: {
            HStack(spacing: Theme.Space.s) {
                Circle().fill(Theme.error).frame(width: 7, height: 7)
                Text("Gravando agora")
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.error)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(RowButtonStyle(highlight: library.selectedID == nil ? .accent : .none))
    }
}

private struct MeetingRow: View {
    let row: MeetingRowModel
    let selected: Bool
    let stage: MeetingStage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: Theme.Space.s) {
                    Text(row.dateText)
                    Text(row.durationText)
                    Spacer(minLength: 0)
                    StatusBadge(badge: row.badge, stage: stage)
                }
                .font(Theme.Font.captionMono)
                .foregroundStyle(Theme.textSecondary)
                if let detail = row.detail {
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(RowButtonStyle(highlight: selected ? .accent : .none, height: row.detail == nil ? 54 : 72))
    }
}

private enum MeetingStatusText {
    static func label(badge: MeetingStatusBadge, stage: MeetingStage?) -> String {
        if case .transcribing(let fraction)? = stage, fraction > 0 { return "\(badge.label) \(Int(fraction * 100))%" }
        return badge.label
    }
}

private struct StatusBadge: View {
    let badge: MeetingStatusBadge
    let stage: MeetingStage?

    private var tint: Color {
        switch badge.tone {
        case .recording, .failed: Theme.error
        case .working: Theme.busy
        case .ready: Theme.ok
        }
    }

    private var label: String { MeetingStatusText.label(badge: badge, stage: stage) }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct MeetingMainCard: View {
    @ObservedObject var model: MeetingRecordingModel
    @ObservedObject var library: MeetingLibraryModel
    @ObservedObject var speech: SpeechModelModel
    @ObservedObject var copilot: MeetingCopilotModel

    init(model: MeetingRecordingModel, library: MeetingLibraryModel, speech: SpeechModelModel) {
        _model = ObservedObject(wrappedValue: model)
        _library = ObservedObject(wrappedValue: library)
        _speech = ObservedObject(wrappedValue: speech)
        _copilot = ObservedObject(wrappedValue: model.copilot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(model.permissionCards) { card in
                PermissionCardView(card: card)
            }
            if let silence = model.silenceCard {
                PermissionCardView(card: silence)
            }
            if let hint = model.permissionHint, model.permissionCards.isEmpty, model.phase == .idle {
                Text(hint)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            if !speech.isReady, speech.state != .checking {
                ModelCard(speech: speech)
            }
            ForEach(visibleWarnings, id: \.self) { warning in
                InlineError(text: warning)
            }
            if let message = model.message {
                NoticeLine(text: message) { model.dismissMessage() }
            }
            if let notice = library.notice {
                NoticeLine(text: notice) { library.dismissNotice() }
            }
            ForEach(library.webhookOffers) { offer in
                WebhookCard(offer: offer, allow: { library.allowWebhook(offer.id) }, dismiss: { library.dismissWebhook(offer.id) })
            }
            content
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private var visibleWarnings: [String] {
        let hidden = RecordingWarning.systemSilent.message
        return model.warnings.filter { $0 != hidden }
    }

    @ViewBuilder
    private var content: some View {
        if let entry = library.selected {
            MeetingDetailView(entry: entry, library: library)
        } else if model.phase != .idle || !model.liveLines.isEmpty {
            LiveSessionView(model: model, copilot: copilot)
        } else {
            VStack(spacing: Theme.Space.m) {
                VStack(spacing: Theme.Space.m) {
                    Spacer(minLength: 0)
                    Text("Escolha uma reunião na lista ou grave uma nova.\nO que for dito aparece aqui em tempo real.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    RecordButton(model: model)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                PrepCard(copilot: copilot)
            }
        }
    }
}

private struct NoticeLine: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(CircleButtonStyle(size: 20))
        }
    }
}

private struct RecordButton: View {
    @ObservedObject var model: MeetingRecordingModel

    var body: some View {
        let control = model.control
        Button {
            model.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: control.isRecording ? "stop.fill" : "mic.fill")
                Text(control.title)
                    .lineLimit(1)
            }
            .fixedSize()
        }
        .buttonStyle(CapsuleButtonStyle(kind: control.isRecording ? .error : .accent))
        .disabled(!control.isEnabled)
        .help("Grava só quando você clica. O áudio fica no seu Mac.")
    }
}

private struct RecorderBar: View {
    @ObservedObject var model: MeetingRecordingModel

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            RecordButton(model: model)
            if let startedAt = model.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(ElapsedFormat.clock(context.date.timeIntervalSince(startedAt)))
                        .font(Theme.Font.captionMono)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                }
                LevelMeter(bar: LevelBar(level: max(model.micLevel, model.systemLevel), active: model.isRecording))
            } else {
                Spacer(minLength: 0)
                if model.phase == .idle {
                    SourceMenu(selection: $model.sources)
                }
            }
        }
    }
}

private struct SourceMenu: View {
    @Binding var selection: RecordingSources

    var body: some View {
        CapsuleMenu(title: selection.shortLabel, help: "Fonte do áudio") {
            ForEach(RecordingSources.allCases) { option in
                Button {
                    selection = option
                } label: {
                    if selection == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        }
    }
}

private struct LevelMeter: View {
    let bar: LevelBar

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule()
                    .fill(bar.fraction > 0.85 ? Theme.busy : Theme.ok)
                    .frame(width: max(0, proxy.size.width * bar.fraction))
                    .animation(.linear(duration: 0.08), value: bar.fraction)
            }
        }
        .frame(minWidth: 30, maxWidth: .infinity)
        .frame(height: 6)
        .help("Nível do áudio")
    }
}

private struct PermissionCardView: View {
    let card: PermissionCard

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: card.neutral ? "speaker.slash" : "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(card.neutral ? Theme.textTertiary : Theme.busy)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                Text(card.message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            Button(card.buttonTitle) { NSWorkspace.shared.open(card.settingsURL) }
                .buttonStyle(CapsuleButtonStyle(kind: card.neutral ? .ghost : .accent))
        }
        .padding(Theme.Space.m)
        .background(card.neutral ? Theme.surfaceHi.opacity(0.6) : Theme.busy.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

private struct ModelCard: View {
    @ObservedObject var speech: SpeechModelModel

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Modelo de transcrição: \(speech.spec.name)")
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                detail
            }
            Spacer(minLength: Theme.Space.s)
            action
        }
        .padding(Theme.Space.m)
        .background(Theme.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var detail: some View {
        switch speech.state {
        case .downloading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .tint(Theme.accent)
            Text("\(ByteCountFormat.megabytes(done)) de \(ByteCountFormat.megabytes(total))")
                .font(Theme.Font.captionMono)
                .foregroundStyle(Theme.textSecondary)
        case .failed(let message):
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
        default:
            Text("Roda no seu Mac, sem enviar o áudio a ninguém. Baixa uma vez (\(speech.sizeText)) para a pasta modelos do Wisp e confere a assinatura de cada arquivo.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(SpeechModelSpec.attribution)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch speech.state {
        case .downloading:
            Button("Cancelar") { speech.cancel() }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
        case .failed:
            Button("Tentar de novo") { speech.download() }
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
        default:
            Button("Baixar") { speech.download() }
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
        }
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.title)
            .foregroundStyle(Theme.textPrimary)
    }
}

private struct MeetingDetailView: View {
    enum Page { case note, transcript }
    private enum Primary { case generate, cancel, brain }

    private static let readableWidth: CGFloat = 720

    let entry: MeetingEntry
    @ObservedObject var library: MeetingLibraryModel
    @Environment(\.navCover) private var navCover
    @State private var page: Page = .note

    private var row: MeetingRowModel { MeetingRowModel(entry: entry, working: library.stage(of: entry.id) != nil) }
    private var detail: MeetingDetail? { library.detail?.id == entry.id ? library.detail : nil }
    private var stage: MeetingStage? { library.stage(of: entry.id) }
    private var brain: MeetingBrainButton { library.brainButton(entry) }

    private var primary: Primary? {
        if stage == .writingNote { return .cancel }
        if stage != nil { return nil }
        if entry.hasTranscript, !entry.hasNote || entry.meta.status == .failed { return .generate }
        if entry.hasNote || entry.hasTranscript { return .brain }
        return nil
    }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            controls
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                header
                if let failure = entry.meta.failure {
                    IssueLine(text: Self.humanFailure(failure), help: failure, actionTitle: "Tentar de novo") {
                        if entry.meta.status == .failed { library.retry(entry) } else { library.regenerateNote(entry) }
                    }
                }
                if let notice = entry.meta.notice {
                    IssueLine(text: notice, help: notice, actionTitle: "Melhorar transcrição") { library.improveTranscript(entry) }
                }
                if let brainError = entry.meta.brainError {
                    IssueLine(text: "Não gravei a nota no brain: \(brainError)", help: brainError, actionTitle: "Tentar de novo") {
                        library.brainAction(entry)
                    }
                }
                pagePicker
                pageContent
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: Self.readableWidth, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func humanFailure(_ failure: String) -> String {
        failure.contains("comando de nota falhou") ? "A nota não foi gerada. Tente de novo." : failure
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.s) {
            Button { library.select(nil) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(CircleButtonStyle())
                .help("Voltar às reuniões")
            Spacer(minLength: Theme.Space.s)
            primaryButton
            moreMenu
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(text: row.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(row.dateText) · \(row.durationText) · \(MeetingStatusText.label(badge: row.badge, stage: stage))")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch primary {
        case .generate:
            Button("Gerar nota") { library.regenerateNote(entry) }
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
                .lineLimit(1)
                .fixedSize()
        case .cancel:
            Button("Cancelar nota") { library.cancelNote(entry.id) }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                .lineLimit(1)
                .fixedSize()
        case .brain:
            Button(brain.label) { library.brainAction(entry) }
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
                .lineLimit(1)
                .fixedSize()
        case nil:
            EmptyView()
        }
    }

    private var moreMenu: some View {
        IconMenu(systemImage: "ellipsis", help: "Mais ações") {
            Button("Copiar") { library.copy(entry) }
                .disabled(entry.hasNote ? false : !entry.hasTranscript)
            if brain.opensNote {
                Button("Abrir nota") { library.openNote(entry) }
            }
            if primary != .brain, !brain.opensNote, entry.hasNote || entry.hasTranscript {
                Button(brain.label) { library.brainAction(entry) }
            }
            if entry.hasTranscript, stage == nil, primary != .generate {
                Button("Gerar nota de novo") { library.regenerateNote(entry) }
            }
            if entry.hasTranscript, stage == nil {
                Button("Melhorar transcrição") { library.improveTranscript(entry) }
            }
            Divider()
            Button("Mostrar no Finder") { library.reveal(entry) }
        }
    }

    private var pagePicker: some View {
        HStack(spacing: 4) {
            pageButton("Nota", .note)
            pageButton("Transcrição", .transcript)
        }
    }

    private func pageButton(_ title: String, _ target: Page) -> some View {
        let chosen = page == target
        return Button { page = target } label: {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(chosen ? Theme.accentText : Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(chosen ? Theme.accentFill : Theme.surface))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    @ViewBuilder
    private var pageContent: some View {
        if detail == nil, entry.hasNote || entry.hasTranscript {
            SkeletonLines(count: 6)
        } else {
            switch page {
            case .note:
                noteContent
            case .transcript:
                transcriptContent
            }
        }
    }

    @ViewBuilder
    private var noteContent: some View {
        if let note = detail?.note {
            MeetingNoteView(markdown: note)
        } else {
            TabMessage(text: library.stage(of: entry.id) != nil ? "Gerando a nota…" : "Ainda não tem nota.")
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if let lines = detail?.lines, !lines.isEmpty {
            TranscriptListView(lines: lines)
        } else {
            TabMessage(text: library.stage(of: entry.id) != nil ? "Transcrevendo…" : "Sem transcrição.")
        }
    }
}

private struct IssueLine: View {
    let text: String
    let help: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Circle().fill(Theme.error).frame(width: 6, height: 6)
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(help)
            Button(actionTitle, action: action)
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
        }
    }
}

private struct MeetingNoteView: View {
    let markdown: String
    @State private var nodes: [BrainBlockNode] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(nodes) { node in
                    BrainBlockView(node: node, source: "", model: BrainModel.shared, depth: 0)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .environment(\.brainReadOnly, true)
        .environment(\.openURL, OpenURLAction { url in
            guard BrainLinkScheme.action(for: url) == nil else { return .handled }
            return BrainLinkRouter.handle(url, source: "", model: BrainModel.shared)
        })
        .task(id: markdown) {
            nodes = BrainMarkdown.parse(markdown).nodes
        }
    }
}

struct TranscriptListView: View {
    let lines: [TranscriptLine]
    @State private var follower = ScrollFollower()
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var userScrolling = false
    @State private var distance = 0.0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(lines) { line in
                    TranscriptLineView(line: line)
                }
            }
            .padding(.vertical, Theme.Space.xs)
        }
        .scrollPosition($position)
        .scrollIndicators(.automatic)
        .onScrollPhaseChange { _, phase in
            let user = phase == .tracking || phase == .interacting || phase == .decelerating
            if userScrolling, phase == .idle { follower.scrolled(distanceFromBottom: distance) }
            userScrolling = user
        }
        .onScrollGeometryChange(for: Double.self) { geometry in
            max(0, geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height)
        } action: { _, value in
            distance = value
            if userScrolling { follower.scrolled(distanceFromBottom: value) }
        }
        .onChange(of: lines) {
            if follower.isPinned { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottom) {
            if follower.showsJumpButton {
                Button("Ir para o fim") {
                    follower.jumpToEnd()
                    position.scrollTo(edge: .bottom)
                }
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
                .padding(.bottom, Theme.Space.s)
            }
        }
    }
}

private struct TranscriptLineView: View {
    let line: TranscriptLine

    var body: some View {
        if line.isBookmark {
            HStack(spacing: Theme.Space.s) {
                Text(line.time)
                    .font(Theme.Font.captionMono)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, alignment: .trailing)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                Text(line.text)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.accentText)
                Rectangle().fill(Theme.stroke).frame(height: 1)
            }
        } else {
            lineBody
        }
    }

    private var lineBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(line.time)
                .font(Theme.Font.captionMono)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .trailing)
            Text(line.speaker)
                .font(Theme.Font.caption)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(line.isMine ? Theme.accentText : Theme.accentTeal)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background((line.isMine ? Theme.accentFill : Theme.accentTeal.opacity(0.16)), in: Capsule())
            Text(line.text)
                .font(Theme.Font.body)
                .foregroundStyle(line.isPartial ? Theme.textSecondary : Theme.textPrimary)
                .italic(line.isPartial)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
