import SwiftUI
import WispCore

struct ModelPickerCard: View {
    private let model = ModelPickerModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Modelo")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text(machineLine)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let status = model.status, status.backend.isMlx, let advice = model.recommendation {
                RecommendationBlock(advice: advice, status: status)
            }
            if let status = model.status, status.backend.isMlx {
                Toggle(isOn: Binding(get: { status.pensar }, set: { model.setThinking($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pensar antes de responder")
                            .font(Theme.Font.bodyMedium)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Desligado, a IA local responde direto e começa em segundos. Ligado, o Qwen3 raciocina antes (de 8 a 12 s a mais para começar), às vezes com respostas melhores.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .disabled(model.busy)
            }
            Text("Neste Mac")
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
            Text("Modelos que rodam aqui pelo MLX, sem internet e sem assinatura. Os menores erram mais ao usar ferramentas: o Wisp limita o que eles podem fazer e avisa na resposta quando passam do limite.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = model.status {
                ForEach(status.models) { local in
                    LocalModelRow(local: local, status: status)
                }
                if !status.backend.isMlx {
                    Text("A IA local usa o servidor compatível com OpenAI em \(status.backend.url) (modelo \(status.active.isEmpty ? "não escolhido" : status.active)). Para voltar aos modelos do Wisp: wisp local backend mlx.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !status.backend.available {
                    Text("Este Wisp não inclui o mlx-lm (o que roda os modelos); atualize o Wisp para baixar um modelo.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.busy)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let error = model.error {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .onAppear { model.refresh() }
    }

    private var machineLine: String {
        let hardware = model.hardware
        return "\(hardware.chip) · \(ModelFit.gigabytes(hardware.totalMemory)) de memória · \(ModelFit.gigabytes(hardware.freeDisk)) livres no disco"
    }
}

private struct LocalModelRow: View {
    let local: LocalModel
    let status: LocalModelStatus
    private let model = ModelPickerModel.shared

    var body: some View {
        let fit = model.fit(local)
        let installed = status.installed.contains(local.tag)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.s) {
                Text(local.name)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                badge(fit.level)
                ForEach(marks, id: \.self) { mark in
                    Text(mark)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent.opacity(0.15)))
                }
                Spacer(minLength: 0)
                action(fit: fit, installed: installed)
            }
            Text("\(ModelFit.gigabytes(local.sizeBytes)) para baixar · nível \(local.tierLabel) · \(local.speedLabel) · \(fit.note)")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(local.limitations)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let short = fit.diskShortBy, !installed {
                Text("Falta espaço em disco: faltam \(ModelFit.gigabytes(short)) livres (tamanho do modelo mais a folga).")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.busy)
            }
            progress
        }
    }

    private var marks: [String] {
        guard status.backend.isMlx, let advice = model.recommendation else { return [] }
        return (advice.best?.tag == local.tag ? ["Melhor para este Mac"] : []) + (advice.fastest?.tag == local.tag ? ["Mais rápido"] : [])
    }

    private func badge(_ level: FitLevel) -> some View {
        let color = level == .fits ? Theme.ok : level == .tight ? Theme.busy : Theme.error
        return Text(level.label)
            .font(Theme.Font.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    @ViewBuilder
    private func action(fit: ModelFit, installed: Bool) -> some View {
        if case .pulling(let tag, _, _) = model.job, tag == local.tag {
            Button("Cancelar") { model.cancel() }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
        } else if installed {
            if status.active == local.tag {
                Text("Em uso")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.ok)
            } else {
                Button("Usar") { model.use(local) }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    .disabled(model.busy)
            }
        } else {
            Button("Baixar") { model.install(local) }
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
                .disabled(model.busy || !fit.canInstall)
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch model.job {
        case .pulling(let tag, let completed, let total) where tag == local.tag:
            jobBar("Baixando", completed: completed, total: total)
        default:
            EmptyView()
        }
    }

    private func jobBar(_ label: String, completed: UInt64, total: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if total > 0 {
                ProgressView(value: Double(completed), total: Double(total))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(total > 0 ? "\(label): \(ModelFit.gigabytes(completed)) de \(ModelFit.gigabytes(total))" : "\(label)…")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

struct RecommendationBlock: View {
    let advice: LocalRecommendation
    let status: LocalModelStatus
    private let model = ModelPickerModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let best = advice.best {
                if advice.isSameModel {
                    line("Melhor e mais rápido para este Mac", pick: best)
                } else {
                    line("Melhor para este Mac", pick: best)
                    if let fastest = advice.fastest { line("Mais rápido", pick: fastest) }
                }
                useButton(best)
            }
            ForEach(advice.notes, id: \.self) { note in
                Text(note.prefix(1).uppercased() + note.dropFirst() + ".")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if advice.bandwidthGBs == nil {
                Text("Sem estimativa de velocidade para este chip.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
    }

    private func line(_ title: String, pick: LocalPick) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(pick.name)")
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
            Text(pick.reason)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func useButton(_ pick: LocalPick) -> some View {
        if model.usingLocalAI, case .pulling(_, let completed, let total) = model.job {
            VStack(alignment: .leading, spacing: 2) {
                if total > 0 {
                    ProgressView(value: Double(completed), total: Double(total))
                } else {
                    ProgressView().controlSize(.small)
                }
                HStack {
                    Text(total > 0 ? "Baixando: \(ModelFit.gigabytes(completed)) de \(ModelFit.gigabytes(total))" : "Preparando…")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    Button("Cancelar") { model.cancel() }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            }
        } else if let local = status.models.first(where: { $0.tag == pick.tag }) {
            Button("Usar IA local") { model.useLocalAI(local) }
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
                .disabled(model.busy)
        }
    }
}

struct LocalAIOffer: View {
    private let model = ModelPickerModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Roda um modelo neste Mac, sem internet e sem assinatura. Dá para trocar depois em Ajustes > Modelo.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = model.status, status.backend.isMlx, let advice = model.recommendation {
                RecommendationBlock(advice: advice, status: status)
            } else {
                ProgressView().controlSize(.small)
            }
            if let error = model.error {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.refresh() }
    }
}
