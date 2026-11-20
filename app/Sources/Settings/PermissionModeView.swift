import SwiftUI
import WispCore

/// The three choices, shared by Ajustes and the setup's "Teu wisp" step. "Sem pedir" asks for a confirm first.
struct PermissionModePicker: View {
    private let model = PermissionModel.shared
    @State private var confirmingBypass = false

    private static let claudeOptions: [(PermissionChoice, String, String)] = [
        (.ask, "Pedir minha aprovação", "O Claude pergunta aqui no Wisp antes de rodar um comando ou mexer num arquivo."),
        (.auto, "Automático", "O Claude decide sozinho o que é seguro; pode executar ações destrutivas sem perguntar."),
        (.bypass, "Sem pedir (perigoso)", "O Claude roda qualquer comando e edita qualquer arquivo sem perguntar."),
    ]

    private static let codexOptions: [(PermissionChoice, String, String)] = [
        (.ask, "Pedir minha aprovação", "O Codex não consegue pedir aprovação aqui, então só lê: não escreve arquivos nem altera nada."),
        (.auto, "Automático", "O Codex revisa sozinho os pedidos de aprovação e só escreve na pasta de trabalho, sem rede."),
        (.bypass, "Sem pedir (perigoso)", "O Codex roda sem perguntar, mas só escreve na pasta de trabalho (nunca na pasta pessoal inteira) e sem rede."),
    ]

    private var options: [(PermissionChoice, String, String)] {
        EngineModel.shared.active == .codex ? Self.codexOptions : Self.claudeOptions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(options, id: \.0) { choice, title, sentence in
                row(choice, title: title, sentence: choice == .auto && model.autoUnavailable
                    ? "Indisponível nesta conta: o Claude não aceitou o modo Automático." : sentence)
            }
            Text("Nas conversas do Telegram, \"Pedir minha aprovação\" roda como Automático.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if confirmingBypass {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(EngineModel.shared.active == .codex
                         ? "Sem pedir, o Codex age sem perguntar dentro da pasta de trabalho. As travas do Wisp (hooks) não existem no Codex: o que protege é o sandbox do sistema."
                         : "Sem pedir, o Claude age sem perguntar nada. Só as regras de bloqueio do Claude e os hooks continuam valendo.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Theme.Space.s) {
                        Button("Usar sem pedir") {
                            confirmingBypass = false
                            model.select(.bypass)
                        }
                        .buttonStyle(CapsuleButtonStyle(kind: .error))
                        Button("Cancelar") { confirmingBypass = false }
                            .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    }
                }
                .padding(Theme.Space.m)
                .background(Theme.error.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
            }
            if let note {
                Text(note)
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
        .onAppear { model.refresh() }
    }

    private var note: String? {
        switch model.setting.source {
        case .claude(let mode):
            let known = model.setting.choice == nil ? " (\(mode), sem equivalente aqui)" : ""
            return "Definido no Claude\(known), em ~/.claude/settings.json. Escolher aqui vale para o Wisp e não muda esse arquivo."
        case .wisp:
            return "Teu perfil é gerenciado fora do Wisp, então esta escolha fica nos ajustes do Wisp; o bot do Telegram neste Mac lê de lá."
        case .profile, .standard:
            return nil
        }
    }

    private func row(_ choice: PermissionChoice, title: String, sentence: String) -> some View {
        let selected = model.setting.choice == choice
        let disabled = choice == .auto && model.autoUnavailable
        return Button {
            guard !selected else { return }
            if choice == .bypass {
                confirmingBypass = true
            } else {
                confirmingBypass = false
                model.select(choice)
            }
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(choice == .bypass ? Theme.error : Theme.textPrimary)
                    Text(sentence)
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
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

/// Ajustes > "Permissões do Claude".
struct PermissionSettingsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissões do \(EngineModel.shared.active.displayName)")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("Vale para as conversas do Wisp a partir da próxima mensagem; uma resposta em andamento termina no modo anterior.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            PermissionModePicker()
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
