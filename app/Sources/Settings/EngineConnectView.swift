import SwiftUI
import WispCore

struct EngineConnectBlock: View {
    @State private var model: EngineConnectModel

    init(_ login: EngineLogin) {
        _model = State(initialValue: EngineConnectModel(login))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            switch model.state {
            case .connected:
                Text("Conectado")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.ok)
            case .waiting:
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Esperando o login no Terminal…")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            case .notInstalled:
                installHelp
            case .notConnected, .timedOut:
                if model.state == .timedOut {
                    Text("O login não apareceu em 10 minutos. Conecte de novo quando quiser.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.busy)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(model.login.buttonTitle) { model.open() }
                    .buttonStyle(CapsuleButtonStyle(kind: .accent))
                Text(model.login.hint)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.error)
            }
        }
        .padding(.leading, 26)
        .task { await model.check() }
        .task(id: model.state) { await model.watch() }
    }

    private var installHelp: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("\(model.login.kind.displayName) não está instalado neste Mac.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            if let command = model.login.installCommand {
                Text("Cole este comando no Terminal para instalar:")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(command)
                    .font(Theme.Font.caption.monospaced())
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copiar comando") { model.copyInstallCommand() }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            } else {
                Button("Veja como instalar") { model.openInstallPage() }
                    .buttonStyle(.plain)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.accent)
            }
            Button("Conferir de novo") { Task { await model.check() } }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
        }
    }
}
