import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Teu wisp": the name of the assistant, the user's name, an avatar and the colors. The values live on the model
/// so the step button (and the DEBUG walkthrough) read the same ones.
struct ProfileStepView: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            labeled("Nome do seu Wisp") {
                field("Wisp", text: $model.profileName)
            }
            labeled("Como o Wisp chama você") {
                field("seu nome", text: $model.profileUserName)
            }
            labeled("Imagem") {
                HStack(spacing: Theme.Space.m) {
                    WispAvatar(size: 56, animates: false, imagePath: model.profileAvatar?.path)
                    Button("Escolher imagem…") { chooseImage() }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    if model.profileAvatar != nil {
                        Button("Usar a padrão") { model.profileAvatar = nil }
                            .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    }
                    Spacer(minLength: 0)
                }
            }
            labeled("Cores") {
                ThemePicker()
            }
            labeled("Permissões do Claude") {
                PermissionModePicker()
            }
            labeled("IA local (opcional)") {
                LocalAIOffer()
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.textTertiary))
            .textFieldStyle(.plain)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.surfaceHi, in: Capsule())
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Escolha uma imagem de até 5 MB"
        if panel.runModal() == .OK { model.profileAvatar = panel.url }
    }
}
