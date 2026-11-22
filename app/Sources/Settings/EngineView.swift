import SwiftUI
import WispCore

struct EngineSettingsCard: View {
    private let model = EngineModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Motor")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("Quem responde no app e no Telegram, a partir da próxima mensagem. Ao trocar, o novo motor retoma pela conversa guardada no Wisp.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(EngineKind.allCases, id: \.self) { kind in
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    row(kind)
                    if let login = EngineLogin(kind) { EngineConnectBlock(login) }
                }
            }
            if model.active == .codex {
                Text("No Codex o Wisp não recebe pedidos de aprovação: o que protege é o sandbox do sistema, e as travas do Wisp (hooks) só existem no Claude. Enviar e-mail continua pedindo a tua aprovação.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.notice {
                Text(notice)
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
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .onAppear { model.refresh() }
    }

    private func row(_ kind: EngineKind) -> some View {
        let selected = model.active == kind
        return Button {
            model.select(kind)
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.textPrimary)
                    Text(model.status(of: kind))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .disabled(model.busy)
    }
}
