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
            Text("Neste Mac")
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
            Text("Modelos que rodam aqui, sem internet e sem assinatura. Os menores erram mais ao usar ferramentas: o Wisp limita o que eles podem fazer e avisa na resposta quando passam do limite.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = model.status {
                ForEach(status.models) { local in
                    LocalModelRow(local: local, status: status)
                }
                if !status.ollama.installed {
                    Text("O Ollama (que roda os modelos) ainda não está instalado; o Wisp instala junto com o primeiro modelo.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
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
        case .installingOllama(let completed, let total) where model.busy && isFirstBusy:
            jobBar("Instalando o Ollama", completed: completed, total: total)
        case .pulling(let tag, let completed, let total) where tag == local.tag:
            jobBar("Baixando", completed: completed, total: total)
        default:
            EmptyView()
        }
    }

    private var isFirstBusy: Bool { status.models.first?.tag == local.tag }

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
