import SwiftUI
import WispCore

struct OnboardingView: View {
    var model: ConversationViewModel
    let openModelSettings: () -> Void

    var body: some View {
        let state = model.onboarding
        VStack(spacing: Theme.Space.l) {
            WispAvatar(size: 56, imagePath: model.profile.persona.avatar)
            VStack(spacing: 6) {
                Text(state.title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text(state.detail)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: Theme.Space.s) {
                if state.action == .openModelSettings {
                    Button("Abrir Ajustes > Modelo", action: openModelSettings)
                        .buttonStyle(CapsuleButtonStyle())
                }
                Button(buttonTitle(state)) { model.recheck() }
                    .buttonStyle(CapsuleButtonStyle(kind: state.action == .openModelSettings ? .ghost : .accent))
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func buttonTitle(_ state: OnboardingState) -> String {
        if case .profileInvalid = state { return "Recarregar perfil" }
        return state.action == .retry ? "Tentar de novo" : "Verificar de novo"
    }
}
