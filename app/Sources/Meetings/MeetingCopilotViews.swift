import SwiftUI
import WispCore

struct LiveSessionView: View {
    @ObservedObject var model: MeetingRecordingModel
    @ObservedObject var copilot: MeetingCopilotModel

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                header
                if let notice = copilot.limitNotice {
                    Text(notice)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.busy)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NudgeChips(copilot: copilot)
                notices
                let lines = copilot.isLive ? copilot.transcriptLines : model.liveLines
                if lines.isEmpty {
                    TabMessage(text: model.isRecording ? "Esperando alguém falar…" : "Nada transcrito ainda.")
                } else {
                    TranscriptListView(lines: lines)
                }
            }
            if copilot.isLive {
                CopilotSidebar(copilot: copilot)
                    .frame(width: 270)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Transcrição ao vivo")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.textPrimary)
            if model.isRecording { Circle().fill(Theme.error).frame(width: 6, height: 6) }
            Spacer(minLength: 0)
            if copilot.isLive {
                Button {
                    copilot.addBookmark()
                } label: {
                    Label("Marcar momento", systemImage: "bookmark")
                }
                .buttonStyle(CompactCapsuleStyle(accent: false))
                .help("Marca este ponto da conversa. Atalho global: \(MeetingCopilotModel.bookmarkShortcut)")
                Text(MeetingCopilotModel.bookmarkShortcut)
                    .font(Theme.Font.captionMono)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if model.liveLagging {
            Text("Transcrição atrasada: o Mac está sobrecarregado. Nada se perde; eu alcanço e refaço tudo quando você parar.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.busy)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let notice = model.liveNotice {
            Text(notice)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NudgeChips: View {
    @ObservedObject var copilot: MeetingCopilotModel

    var body: some View {
        if !copilot.nudges.isEmpty {
            HStack(spacing: Theme.Space.s) {
                ForEach(copilot.nudges) { nudge in
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 10, weight: .semibold))
                        Text(nudge.text)
                            .font(Theme.Font.caption)
                        Button { copilot.dismiss(nudge) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain)
                            .pointerStyle(.link)
                    }
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.accentFill))
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct CopilotSidebar: View {
    @ObservedObject var copilot: MeetingCopilotModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                MetricsCard(stats: copilot.stats)
                if !copilot.checklist.isEmpty { ChecklistCard(copilot: copilot, title: "Checklist") }
                AssistCard(copilot: copilot)
                if copilot.brainAvailable { BrainCard(copilot: copilot) }
                SwitchRow(title: "Avisos gentis", detail: "Um aviso discreto, no máximo a cada 5 min. Sem som.", isOn: $copilot.nudgesOn)
                    .sidebarCard()
            }
        }
        .scrollIndicators(.hidden)
    }
}

private extension View {
    func sidebarCard() -> some View {
        padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

private struct CardTitle: View {
    let text: String
    var icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accent)
                .labelsHidden()
        }
    }
}

private struct MetricsCard: View {
    let stats: MeetingStats

    var body: some View {
        let metrics = stats.metrics
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: "Conversa", icon: "chart.bar")
            HStack(spacing: 0) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.accentTeal.opacity(0.5))
                        Capsule().fill(Theme.accent).frame(width: proxy.size.width * metrics.youShare)
                    }
                }
                .frame(height: 6)
            }
            row("Fala", spoken(metrics) > 0 ? "Você \(percent(metrics.youShare)) · Outros \(percent(1 - metrics.youShare))" : "—")
            row("Palavras/min (Você · Outros)", "\(Int(metrics.you.wordsPerMinute.rounded())) · \(Int(metrics.others.wordsPerMinute.rounded()))")
            row("Perguntas (Você · Outros)", "\(metrics.you.questions) · \(metrics.others.questions)")
            row("Maior monólogo (Você · Outros)", "\(ElapsedFormat.clock(metrics.you.longestMonologueSeconds)) · \(ElapsedFormat.clock(metrics.others.longestMonologueSeconds))")
            row("Silêncio", ElapsedFormat.clock(metrics.silenceSeconds))
        }
        .sidebarCard()
    }

    private func spoken(_ metrics: MeetingMetrics) -> Double { metrics.you.speakingSeconds + metrics.others.speakingSeconds }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Text(value)
                .font(Theme.Font.captionMono)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

struct ChecklistCard: View {
    @ObservedObject var copilot: MeetingCopilotModel
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: title, icon: "checklist")
            ForEach(copilot.checklist) { item in
                Button { copilot.toggle(item) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.done ? Theme.accent : Theme.textTertiary)
                        Text(item.text)
                            .font(Theme.Font.caption)
                            .foregroundStyle(item.done ? Theme.textTertiary : Theme.textPrimary)
                            .strikethrough(item.done)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
        .sidebarCard()
    }
}

private struct AssistCard: View {
    @ObservedObject var copilot: MeetingCopilotModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: "Copiloto", icon: "sparkles")
            SwitchRow(
                title: "Sugestões ao vivo",
                detail: "Lê os últimos 4 min da transcrição e propõe até 3 itens, no máximo a cada 40 s. Cada rodada chama o motor ativo (Claude ou modelo local, sem ferramentas) e usa o seu plano.",
                isOn: $copilot.assistOn
            )
            if copilot.assistOn {
                if let status = copilot.assistStatus {
                    Text(status)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(copilot.assistItems) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.kind.label)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.accentText)
                        Text(item.text)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .sidebarCard()
    }
}

private struct BrainCard: View {
    @ObservedObject var copilot: MeetingCopilotModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle(text: "No brain", icon: "brain")
            if copilot.brainHits.isEmpty {
                Text("Quando alguém citar um nome, cliente ou projeto, as notas do brain aparecem aqui.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(copilot.brainHits) { hit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(hit.title)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Abrir") { copilot.openHit(hit) }
                            .buttonStyle(CompactCapsuleStyle(accent: false))
                    }
                    if !hit.snippet.isEmpty {
                        Text(hit.snippet)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .sidebarCard()
    }
}

struct PrepCard: View {
    @ObservedObject var copilot: MeetingCopilotModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            CardTitle(text: "Preparar a reunião", icon: "list.bullet.clipboard")
            HStack(spacing: Theme.Space.s) {
                Picker("Evento", selection: $copilot.selectedEventID) {
                    Text("Sem evento da agenda").tag(String?.none)
                    ForEach(copilot.events) { event in
                        Text("\(Self.time(event.start)) \(event.title)").tag(Optional(event.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Button("Atualizar") { copilot.loadEvents() }
                    .buttonStyle(CompactCapsuleStyle(accent: false))
            }
            TextField("", text: $copilot.prepText, prompt: Text("ou descreva a reunião").foregroundStyle(Theme.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...3)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: Theme.Space.s) {
                if copilot.prepBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancelar") { copilot.cancelPrep() }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                } else {
                    Button(copilot.checklist.isEmpty ? "Gerar checklist" : "Gerar de novo") { copilot.generatePrep() }
                        .buttonStyle(CapsuleButtonStyle(kind: .accent))
                        .disabled(!copilot.hasPrep)
                }
                Text("Usa o motor ativo (Claude ou modelo local), sem ferramentas e nunca o Codex. Título, notas e participantes do evento vão ao motor.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = copilot.prepMessage {
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !copilot.checklist.isEmpty {
                ChecklistCard(copilot: copilot, title: "Checklist (aparece durante a gravação e vai para a nota)")
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onAppear { copilot.loadEvents() }
    }

    private static func time(_ start: String) -> String {
        guard let marker = start.firstIndex(of: "T") else { return "" }
        return String(start[start.index(after: marker)...].prefix(5))
    }
}

struct WebhookCard: View {
    let offer: WebhookOffer
    let allow: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "paperplane")
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Enviar \"\(offer.title)\" para \(offer.pending.host)?")
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(offer.pending.sizeText) em JSON: a nota, as métricas e as ações. A transcrição não vai. Nada é enviado sem o seu clique.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(offer.pending.url.absoluteString)
                    .font(Theme.Font.tool)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.s)
            Button("Agora não", action: dismiss)
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            Button("Permitir", action: allow)
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
        }
        .padding(Theme.Space.m)
        .background(Theme.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
