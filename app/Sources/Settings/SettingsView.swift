import AppKit
import SwiftUI
import WispCore

struct SettingsView: View {
    @ObservedObject var media: NowPlayingService
    private let settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.cardGap) {
                Text("Ajustes")
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.textPrimary)
                colors
                home
                music
                SpotifySettingsCard()
                clipboard
                if let notice = settings.notice {
                    Text(notice)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.busy)
                }
            }
            .padding(.top, Theme.Space.xs)
        }
        .scrollIndicators(.automatic)
        .onAppear {
            NSColorPanel.shared.level = NSWindow.Level(rawValue: NotchPanel.windowLevel.rawValue + 1)
            media.refresh()
        }
        .onDisappear {
            if NSColorPanel.shared.isVisible { NSColorPanel.shared.close() }
        }
    }

    // MARK: Cores

    private var colors: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                sectionTitle("Cores")
                Spacer()
                Button("Restaurar padrão") { settings.restoreDefaults() }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    .disabled(settings.settings.theme == WispSettings.default.theme && settings.settings.custom == nil)
            }
            HStack(spacing: Theme.Space.s) {
                ForEach(ThemePreset.all) { preset in
                    Swatch(
                        name: preset.name,
                        fill: Color(preset.accent),
                        selected: settings.settings.theme == preset.id
                    ) { settings.selectPreset(preset) }
                }
                Swatch(
                    name: "Personalizado",
                    fill: settings.settings.isCustom ? Theme.accent : Theme.surfaceHi,
                    icon: "paintpalette.fill",
                    selected: settings.settings.isCustom
                ) { settings.selectCustom() }
            }
            if settings.settings.isCustom {
                VStack(spacing: Theme.Space.s) {
                    CustomColorRow(label: "Destaque", color: settings.colors.accent) { settings.setCustom(\.accent, to: $0) }
                    CustomColorRow(label: "Fundo", color: settings.colors.background) { settings.setCustom(\.background, to: $0) }
                    CustomColorRow(label: "Superfície", color: settings.colors.surface) { settings.setCustom(\.surface, to: $0) }
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Início

    private var home: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Início")
                Text("Arraste os cartões do Início para reordenar.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Restaurar ordem do Início") { settings.restoreDashboardOrder() }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                .disabled(settings.settings.dashboardOrder == DashboardTileID.defaultOrder)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Música

    private var music: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            sectionTitle("Música")
            ForEach(MediaPlayer.allCases, id: \.self) { player in
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Text(player.name)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 70, alignment: .leading)
                    AutomationPromptView(media: media, player: player, showsGranted: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Copiados

    private var clipboard: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Copiados")
                Text("Guardar o que você copia enquanto o Wisp roda. Senhas de gerenciadores nunca entram.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Toggle("Guardar copiados", isOn: Binding(
                get: { settings.settings.clipboardCapture },
                set: { settings.setClipboardCapture($0) }
            ))
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .labelsHidden()
            .pointerStyle(.link)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.title)
            .foregroundStyle(Theme.textPrimary)
    }
}

private struct Swatch: View {
    let name: String
    let fill: Color
    var icon: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(fill)
                    .frame(width: 28, height: 28)
                    .overlay {
                        if let icon {
                            Image(systemName: icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(selected ? Theme.bg : Theme.textSecondary)
                        }
                    }
                    .padding(3)
                    .overlay {
                        Circle().strokeBorder(selected ? Theme.textPrimary : (hovering ? Theme.stroke : .clear), lineWidth: 2)
                    }
                Text(name)
                    .font(Theme.Font.caption)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(name)
    }
}

private struct CustomColorRow: View {
    let label: String
    let color: HexColor
    let set: (HexColor) -> Void
    @State private var draft = ""
    @State private var invalid = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(label)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 80, alignment: .leading)
            ColorPicker(label, selection: pickerBinding, supportsOpacity: false)
                .labelsHidden()
            TextField("#RRGGBB", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.Font.tool)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(width: 96, height: 26)
                .background(Theme.surfaceHi, in: Capsule())
                .onSubmit(apply)
                .onChange(of: draft) { _, text in
                    if let parsed = HexColor(text) {
                        invalid = false
                        if parsed != color { set(parsed) }
                    } else {
                        invalid = !text.isEmpty
                    }
                }
            if invalid {
                Text("Use o formato #RRGGBB")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.error)
            }
            Spacer(minLength: 0)
        }
        .onAppear { draft = color.hex }
        .onChange(of: color) { _, new in
            if HexColor(draft) != new { draft = new.hex }
        }
    }

    private var pickerBinding: Binding<Color> {
        Binding(
            get: { Color(color) },
            set: { picked in
                if let hex = HexColor(picked), hex != color { set(hex) }
            }
        )
    }

    private func apply() {
        if let parsed = HexColor(draft) {
            invalid = false
            set(parsed)
            draft = parsed.hex
        } else {
            invalid = true
        }
    }
}

extension HexColor {
    init?(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
        self.init(red: channel(rgb.redComponent), green: channel(rgb.greenComponent), blue: channel(rgb.blueComponent))
    }
}
