import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WispCore

/// Settings > Integrações > Google Agenda: import the user's OAuth client, sign in, list and disconnect accounts.
struct GoogleSettingsCard: View {
    private let google = GoogleModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(status)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            if !google.hasClient {
                GoogleSetupSteps()
            }
            HStack(spacing: Theme.Space.s) {
                Button(google.hasClient ? "Trocar o JSON…" : "Importar credentials.json…", action: importClient)
                    .buttonStyle(CapsuleButtonStyle(kind: google.hasClient ? .ghost : .accent))
                if google.hasClient {
                    if google.phase == .signingIn {
                        Button("Cancelar") { google.cancelConnect() }
                            .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    } else {
                        Button(google.isConnected ? "Conectar outra conta" : "Conectar") { google.connect() }
                            .buttonStyle(CapsuleButtonStyle(kind: .accent))
                    }
                    Button("Remover cliente") { google.removeClient() }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            }
            ForEach(google.accounts, id: \.self) { email in
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "person.crop.circle").foregroundStyle(Theme.textTertiary)
                    Text(email).font(Theme.Font.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Desconectar") { google.disconnect(email) }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            }
            if let error = google.error {
                InlineError(text: error)
            }
        }
        .onAppear { google.reload() }
    }

    private var status: String {
        if google.phase == .signingIn { return "Conectando pelo navegador…" }
        if google.isConnected { return "Conectado. Responda convites (Sim, Talvez, Não) no detalhe do evento. Os acessos ficam só no Keychain deste Mac." }
        if google.hasClient { return "Cliente importado. Clique em Conectar e entre com a sua conta do Google." }
        return "O macOS não deixa o Wisp responder convites; pelo Google dá. Cada pessoa cria o próprio cliente OAuth, gratuito."
    }

    private func importClient() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Escolha o credentials.json baixado do Google Cloud."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        google.importClient(from: url)
    }
}

private struct GoogleSetupSteps: View {
    private static let steps = [
        "No Google Cloud Console, crie um projeto e ative a \"Google Calendar API\".",
        "Em Tela de consentimento OAuth, escolha Externo, adicione o seu e-mail como usuário de teste.",
        "Em Credenciais, crie um \"ID do cliente OAuth\" do tipo \"App para computador\".",
        "Baixe o JSON (credentials.json) e importe aqui.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, text in
                Text("\(index + 1). \(text)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
