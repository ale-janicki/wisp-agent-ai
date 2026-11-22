import SwiftUI
import WispCore

private struct OpenTabSettingsKey: EnvironmentKey {
    static var defaultValue: (PanelTab) -> Void { { _ in } }
}

extension EnvironmentValues {
    var openTabSettings: (PanelTab) -> Void {
        get { self[OpenTabSettingsKey.self] }
        set { self[OpenTabSettingsKey.self] = newValue }
    }
}

struct TabSettingsButton: View {
    let tab: PanelTab
    @Environment(\.openTabSettings) private var open

    var body: some View {
        if TabSettings.hasSettings(tab.rawValue) {
            Button { open(tab) } label: { Image(systemName: "gearshape") }
                .buttonStyle(CircleButtonStyle(size: 24))
                .help("Ajustes de \(tab.title)")
        }
    }
}

struct TabSettingsPage: View {
    let tab: PanelTab
    @ObservedObject var media: NowPlayingService
    let back: () -> Void
    let openAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Button(action: back) {
                    Label("Voltar", systemImage: "chevron.left")
                }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                Text("Ajustes de \(tab.title)")
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                Button("Todos os ajustes", action: openAll)
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Layout.cardGap) {
                    ForEach(TabSettings.blocks(forTab: tab.rawValue), id: \.self) { block in
                        view(for: block)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, Theme.Space.xs)
        .onAppear { media.refresh() }
    }

    @ViewBuilder
    private func view(for block: TabSettingsBlock) -> some View {
        switch block {
        case .engine: EngineSettingsCard()
        case .model: ModelPickerCard()
        case .permission: PermissionSettingsCard()
        case .brain: BrainSettingsGroup()
        case .agenda: AgendaSettingsGroup()
        case .meetings: MeetingsSettingsGroup()
        case .macControl: MacControlSettingsGroup()
        case .integrations: IntegrationsPane(media: media)
        }
    }
}
