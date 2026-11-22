import SwiftUI
import WispCore

struct ModelPickerCard: View {
    private let model = ModelPickerModel.shared
    private let engine = EngineModel.shared
    @State private var localOpen = false

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
            if engine.active == .local {
                localContent
            } else {
                collapsedLocal
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

    @ViewBuilder
    private var localContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
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
            Text("Rodam aqui pelo MLX, sem internet e sem assinatura.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            if let status = model.status {
                VStack(spacing: 0) {
                    ForEach(Array(status.models.enumerated()), id: \.element.id) { index, local in
                        if index > 0 { Divider().overlay(Theme.stroke) }
                        LocalModelRow(local: local, status: status)
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .background(Theme.surfaceHi.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                if !status.backend.isMlx {
                    Text("A IA local usa o servidor compatível com OpenAI em \(status.backend.url) (modelo \(status.active.isEmpty ? "não escolhido" : status.active)). Para voltar aos modelos do Wisp: wisp local backend mlx.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !status.backend.available, LocalAdvisor.appleSilicon(model.hardware.chip) {
                    Text(ModelPickerModel.runtimeNote)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.busy)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Tentar de novo") {
                        Task {
                            await (NSApp.delegate as? AppDelegate)?.retryRuntime()
                            model.refresh()
                        }
                    }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            } else {
                VStack(spacing: Theme.Space.s) {
                    ForEach(0..<3, id: \.self) { _ in
                        Skeleton(cornerRadius: Theme.Radius.bubble).frame(height: 56)
                    }
                }
            }
        }
    }

    private var collapsedLocal: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("IA local neste Mac")
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                Text(localSummary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Button {
                localOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: localOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text("Ver modelos locais")
                }
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            if localOpen { localContent }
        }
    }

    private var localSummary: String {
        guard let status = model.status else { return "Conferindo os modelos…" }
        var parts: [String] = []
        if status.backend.isMlx, let best = model.recommendation?.best { parts.append("\(best.name) recomendado") }
        let count = status.installed.count
        parts.append(count == 1 ? "1 baixado" : count == 0 ? "nenhum baixado" : "\(count) baixados")
        return parts.joined(separator: " · ")
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
    @State private var detailsOpen = false
    @State private var confirmingDelete = false

    var body: some View {
        let fit = model.fit(local)
        let presence = status.presence(of: local.tag)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(local.name)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.textPrimary)
                    Text(summary(presence))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                    chips(fit: fit, presence: presence)
                }
                Spacer(minLength: 0)
                action(fit: fit, presence: presence)
            }
            progress
            detailsToggle
            if detailsOpen { details(fit: fit, presence: presence) }
        }
        .padding(.vertical, Theme.Space.m)
        .confirmationDialog("Apagar o \(local.name)?", isPresented: $confirmingDelete) {
            Button("Apagar", role: .destructive) { model.remove(local) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Libera \(ModelFit.gigabytes(local.sizeBytes)) no disco. Dá para baixar de novo depois.")
        }
    }

    private func summary(_ presence: LocalModelPresence) -> String {
        let size = presence == .absent || presence == .resumable
            ? "\(ModelFit.gigabytes(local.sizeBytes)) para baixar" : ModelFit.gigabytes(local.sizeBytes)
        return "\(size) · usa ~\(ModelFit.gigabytes(local.memoryBytes)) de memória · \(local.speedLabel)"
    }

    private func chips(fit: ModelFit, presence: LocalModelPresence) -> some View {
        HStack(spacing: Theme.Space.xs) {
            if status.backend.isMlx, model.recommendation?.best?.tag == local.tag { chip("Recomendado", Theme.accent) }
            switch presence {
            case .inUse: chip("Em uso", Theme.ok)
            case .downloaded: chip("Já baixado", Theme.ok)
            case .absent, .resumable, .downloading:
                if fit.level == .tight { chip("Apertado", Theme.busy) }
                if fit.level == .doesNotFit { chip("Não cabe", Theme.error) }
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var detailsToggle: some View {
        Button {
            detailsOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: detailsOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                Text("Detalhes")
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
        }
        .buttonStyle(.plain)
    }

    private func details(fit: ModelFit, presence: LocalModelPresence) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Nível \(local.tierLabel) · \(fit.note)")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(local.limitations)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
            if let short = fit.diskShortBy, presence == .absent || presence == .resumable {
                Text("Falta espaço em disco: faltam \(ModelFit.gigabytes(short)) livres (tamanho do modelo mais a folga).")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.busy)
            }
            if presence == .downloaded || presence == .inUse || presence == .resumable {
                Button("Apagar") { confirmingDelete = true }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    .disabled(model.busy)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func action(fit: ModelFit, presence: LocalModelPresence) -> some View {
        if case .pulling(let tag, _, _) = model.job, tag == local.tag {
            Button("Cancelar") { model.cancel() }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
        } else {
            switch presence {
            case .inUse:
                Text("Em uso")
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.ok)
            case .downloaded:
                Button("Usar") { model.useLocalAI(local) }
                    .buttonStyle(CapsuleButtonStyle(kind: .accent))
                    .disabled(model.busy)
            case .downloading:
                Button("Baixando…") {}
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    .disabled(true)
            case .resumable:
                Button("Retomar download") { model.install(local) }
                    .buttonStyle(CapsuleButtonStyle(kind: .accent))
                    .disabled(model.busy || !fit.canInstall)
            case .absent:
                Button("Baixar") { model.install(local) }
                    .buttonStyle(CapsuleButtonStyle(kind: .accent))
                    .disabled(model.busy || !fit.canInstall)
            }
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

    private func useLabel(_ local: LocalModel, _ presence: LocalModelPresence) -> String {
        switch presence {
        case .downloaded, .inUse: "Usar \(local.name) (já baixado)"
        case .resumable: "Retomar download e usar IA local"
        case .absent, .downloading: "Usar IA local"
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
            Button(useLabel(local, status.presence(of: local.tag))) { model.useLocalAI(local) }
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
                .disabled(model.busy)
        }
    }
}
