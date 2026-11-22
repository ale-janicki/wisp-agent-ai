import AppKit
import SwiftUI
import WispCore

struct MeetingsTab: View {
    @ObservedObject var model: MeetingRecordingModel
    @ObservedObject private var library: MeetingLibraryModel
    @ObservedObject private var speech: SpeechModelModel

    init(model: MeetingRecordingModel) {
        self.model = model
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
            model.refreshPermissions()
            speech.refresh()
            library.reload(thenProcess: true)
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
                if model.phase != .idle {
                    liveRow
                }
                if library.rows.isEmpty {
                    TabMessage(text: "Nenhuma reunião ainda.\nGrave a primeira ao lado.")
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

    private var label: String {
        if case .transcribing(let fraction)? = stage, fraction > 0 { return "\(badge.label) \(Int(fraction * 100))%" }
        return badge.label
    }

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
            RecorderPanel(model: model)
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
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = library.notice {
                HStack(spacing: Theme.Space.s) {
                    Text(notice)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Button { library.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(CircleButtonStyle(size: 20))
                }
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
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                PrepCard(copilot: copilot)
                TabMessage(text: "Escolha uma reunião na lista ou clique em Gravar.\nO que for dito aparece aqui em tempo real.")
            }
        }
    }
}

private struct RecorderPanel: View {
    @ObservedObject var model: MeetingRecordingModel

    var body: some View {
        let control = model.control
        HStack(alignment: .center, spacing: Theme.Space.l) {
            Button {
                model.toggle()
            } label: {
                ZStack {
                    Circle().fill(control.isRecording ? Theme.error : Theme.accent)
                    Image(systemName: control.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                }
                .frame(width: 60, height: 60)
                .opacity(control.isEnabled ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .pointerStyle(control.isEnabled ? .link : nil)
            .disabled(!control.isEnabled)
            .help("Grava só quando você clica. O áudio fica no seu Mac.")

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    if let startedAt = model.startedAt {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(ElapsedFormat.clock(context.date.timeIntervalSince(startedAt)))
                                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    } else {
                        Text(control.timer)
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(control.title)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(control.isRecording ? Theme.error : Theme.textSecondary)
                }
                SourcePicker(selection: $model.sources)
                    .disabled(model.phase != .idle)
                    .opacity(model.phase == .idle ? 1 : 0.6)
            }

            Spacer(minLength: Theme.Space.m)

            VStack(alignment: .leading, spacing: 6) {
                LevelRow(label: "Você", bar: LevelBar(level: model.micLevel, active: model.isRecording && model.sources.usesMic))
                LevelRow(label: "Mac", bar: LevelBar(level: model.systemLevel, active: model.isRecording && model.sources.usesSystem))
            }
            .frame(width: 150)
        }
        .padding(Theme.Space.m)
        .background(Theme.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

private struct SourcePicker: View {
    @Binding var selection: RecordingSources

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RecordingSources.allCases) { option in
                let chosen = selection == option
                Button {
                    selection = option
                } label: {
                    Text(option.shortLabel)
                        .font(Theme.Font.caption)
                        .foregroundStyle(chosen ? Theme.accentText : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(chosen ? Theme.accentFill : Theme.surface))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(option.label)
            }
        }
    }
}

private struct LevelRow: View {
    let label: String
    let bar: LevelBar

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(bar.active ? Theme.textSecondary : Theme.textTertiary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface)
                    Capsule()
                        .fill(bar.fraction > 0.85 ? Theme.busy : Theme.ok)
                        .frame(width: max(0, proxy.size.width * bar.fraction))
                        .animation(.linear(duration: 0.08), value: bar.fraction)
                }
            }
            .frame(height: 6)
        }
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

    let entry: MeetingEntry
    @ObservedObject var library: MeetingLibraryModel
    @State private var page: Page = .note

    private var row: MeetingRowModel { MeetingRowModel(entry: entry, working: library.stage(of: entry.id) != nil) }
    private var detail: MeetingDetail? { library.detail?.id == entry.id ? library.detail : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                SectionTitle(text: row.title)
                    .lineLimit(1)
                StatusBadge(badge: row.badge, stage: library.stage(of: entry.id))
                Spacer(minLength: 0)
                Text("\(row.dateText) · \(row.durationText)")
                    .font(Theme.Font.captionMono)
                    .foregroundStyle(Theme.textTertiary)
            }
            if let failure = entry.meta.failure {
                InlineError(text: failure)
            }
            actions
            pagePicker
            pageContent
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Abrir nota") { library.openNote(entry) }
                .disabled(!entry.hasNote)
            Button("Copiar") { library.copy(entry) }
                .disabled(entry.hasNote ? false : !entry.hasTranscript)
            Button(entry.meta.brainNote == nil ? "Salvar no brain" : "Salvar de novo no brain") { library.saveToBrain(entry) }
                .disabled(!entry.hasNote)
            if entry.meta.status == .failed {
                Button("Tentar de novo") { library.retry(entry) }
            } else if library.stage(of: entry.id) == .writingNote {
                Button("Cancelar nota") { library.cancelNote(entry.id) }
            } else if entry.hasTranscript, library.stage(of: entry.id) == nil {
                Button(entry.hasNote ? "Gerar nota de novo" : "Gerar nota") { library.regenerateNote(entry) }
            }
            Button("Mostrar no Finder") { library.reveal(entry) }
            Spacer(minLength: 0)
        }
        .buttonStyle(CompactCapsuleStyle(accent: false))
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
        switch page {
        case .note:
            if let note = detail?.note {
                ScrollView {
                    Text(Self.rendered(note))
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            } else {
                TabMessage(text: library.stage(of: entry.id) != nil ? "Gerando a nota…" : "Ainda não tem nota.")
            }
        case .transcript:
            if let lines = detail?.lines, !lines.isEmpty {
                TranscriptListView(lines: lines)
            } else {
                TabMessage(text: library.stage(of: entry.id) != nil ? "Transcrevendo…" : "Sem transcrição.")
            }
        }
    }

    private static func rendered(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
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
                .foregroundStyle(line.isMine ? Theme.accentText : Theme.accentTeal)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background((line.isMine ? Theme.accentFill : Theme.accentTeal.opacity(0.16)), in: Capsule())
            Text(line.text)
                .font(Theme.Font.body)
                .foregroundStyle(line.isPartial ? Theme.textSecondary : Theme.textPrimary)
                .italic(line.isPartial)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
