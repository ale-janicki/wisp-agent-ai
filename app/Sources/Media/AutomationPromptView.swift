import SwiftUI

struct AutomationPromptView: View {
    @ObservedObject var media: NowPlayingService
    let player: MediaPlayer
    var showsGranted = false
    var centered = false

    private var status: AutomationStatus { media.automationStatus(for: player) }

    var body: some View {
        switch status {
        case .granted:
            if showsGranted {
                line(dot: Theme.ok, "O Wisp controla o \(player.name).")
            }
        case .notRunning:
            line(dot: Theme.textTertiary, "Abra o \(player.name) para pedir a permissão")
        case .notDetermined:
            stack {
                line(dot: Theme.busy, "O Wisp ainda não pode controlar o \(player.name).")
                Button(media.requesting == player ? "Aguardando resposta…" : "Permitir controle do \(player.name)") {
                    media.requestAutomation(for: player)
                }
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
                .disabled(media.requesting != nil)
            }
        case .denied:
            stack {
                line(dot: Theme.error, "O controle do \(player.name) foi negado; libere em Ajustes > Automação.")
                Button("Abrir Ajustes") { media.openAutomationSettings() }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
        }
    }

    @ViewBuilder
    private func stack(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: Theme.Space.s) { content() }
    }

    private func line(dot: Color, _ text: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(centered ? .center : .leading)
        }
    }
}
