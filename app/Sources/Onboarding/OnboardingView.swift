import SwiftUI

struct OnboardingView: View {
    var model: ConversationViewModel

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            WispAvatar(size: 56, imagePath: model.profile.persona.avatar)
            VStack(spacing: 6) {
                Text(title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
            Button(model.profileError == nil ? "Verificar de novo" : "Recarregar perfil") { model.recheck() }
                .buttonStyle(CapsuleButtonStyle())
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if model.profileError != nil { return "Perfil inválido" }
        if model.onboarding == .authRequired { return "Claude Code não está autenticado" }
        return "Falta o Claude Code"
    }

    private var detail: String {
        if let error = model.profileError { return error }
        switch model.onboarding {
        case .authRequired:
            return "O Claude Code não está autenticado. Rode `claude` e depois `/login` no Terminal, ou configure uma API key."
        default:
            return "Instale o Claude Code e rode `claude` e depois `/login` no Terminal."
        }
    }
}
