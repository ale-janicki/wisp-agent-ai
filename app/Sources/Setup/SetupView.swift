import AppKit
import SwiftUI
import WispCore

enum RuntimeFailure {
    static func describe(_ text: String) -> (sentence: String, detail: String?) {
        switch RuntimeSync.classify(text) {
        case .lock, .stalled: return (text, nil)
        case .offline: return ("Sem internet — conecte e tente de novo", text)
        case .other: break
        }
        return ("Não deu para preparar o Wisp", text)
    }
}

struct SetupView: View {
    let session: SetupSession
    let finish: () -> Void

    var body: some View {
        SetupScreen(phase: session.runtime.phase, model: session.model, retry: session.retryRuntime, finish: finish)
            .onChange(of: session.runtime.phase, initial: true) { _, phase in session.adopt(phase) }
    }
}

struct SetupScreen: View {
    let phase: RuntimeInstaller.Phase
    let model: SetupModel?
    let retry: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                WispAvatar(size: 28, animates: false)
                Text("Configurar o Wisp")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
            }
            RuntimeLine(phase: phase, retry: retry)
            if let model {
                SetupBody(model: model, finish: finish)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.xl)
        .frame(width: 720, height: 520, alignment: .topLeading)
        .background(Theme.bg)
    }
}

struct RuntimeLine: View {
    let phase: RuntimeInstaller.Phase
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .checking:
            working("Preparando o Wisp…")
        case .installing(let label):
            working("Preparando o Wisp… \(label)")
        case .ready:
            EmptyView()
        case .failed(let text):
            HStack(spacing: Theme.Space.m) {
                Text(RuntimeFailure.describe(text).sentence)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.error)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Tentar de novo", action: retry)
                    .buttonStyle(CapsuleButtonStyle())
            }
        }
    }

    private func working(_ label: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }
}

struct SetupBody: View {
    @Bindable var model: SetupModel
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            thisMac
            Text("Motor")
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
            if let offer = model.offer {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    LocalCard(model: model, offer: offer)
                    ProviderCard(model: model, offer: offer, kind: .claude)
                    ProviderCard(model: model, offer: offer, kind: .codex)
                }
                if let note = offer.note {
                    Text(note)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            footer
        }
    }

    private var thisMac: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Este Mac")
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
            Text("\(model.hardware.chip) · \(ModelFit.gigabytes(model.hardware.totalMemory)) de memória · \(ModelFit.gigabytes(model.hardware.freeDisk)) livres no disco")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            switch model.phase {
            case .running(let label):
                ProgressView().controlSize(.small)
                Text(label + "…")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
            case .failed(let text):
                Text(text)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.error)
                    .lineLimit(3)
                Button("Tentar de novo") { start() }
                    .buttonStyle(CapsuleButtonStyle())
            default:
                EmptyView()
            }
            Spacer(minLength: 0)
            if !isFailed {
                Button("Começar") { start() }
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(model.phase != .ready)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    private func start() {
        Task {
            if await model.begin() { finish() }
        }
    }
}

private struct EngineCard<Content: View>: View {
    let selected: Bool
    let enabled: Bool
    let select: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) { content }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(selected ? Theme.accentFill : Theme.surface, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 1.5 : 1))
            .opacity(enabled ? 1 : 0.55)
            .contentShape(shape)
            .onTapGesture { if enabled { select() } }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous) }
}

private struct LocalCard: View {
    @Bindable var model: SetupModel
    let offer: SetupOffer

    var body: some View {
        EngineCard(selected: model.engine == .local, enabled: offer.localAvailable, select: { model.engine = .local }) {
            HStack {
                Text("IA local")
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                if offer.recommended != nil { chip("Recomendada") }
            }
            if offer.localAvailable {
                Picker("Modelo", selection: Binding(
                    get: { model.modelTag ?? offer.defaultModelTag ?? "" },
                    set: { model.modelTag = $0; model.engine = .local }
                )) {
                    ForEach(offer.options) { option in
                        Text(option.menuTitle).tag(option.tag).disabled(!option.enabled)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(model.isRunning)
                if let line = offer.option(model.modelTag)?.line {
                    Text(line)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Indisponível neste Mac")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.accent.opacity(0.15)))
    }
}

private struct ProviderCard: View {
    @Bindable var model: SetupModel
    let offer: SetupOffer
    let kind: EngineKind

    var body: some View {
        let selected = model.engine == kind
        EngineCard(selected: selected, enabled: true, select: { model.engine = kind }) {
            Text(kind.displayName)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
            Text("Use tua conta do \(kind.displayName)")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            if selected, let line = offer.providerLine(kind) {
                Text(line)
                    .font(Theme.Font.caption)
                    .foregroundStyle(line == SetupOffer.connected ? Theme.ok : Theme.busy)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
