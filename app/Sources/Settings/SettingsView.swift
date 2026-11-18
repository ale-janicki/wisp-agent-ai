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
                notices
                music
                SpotifySettingsCard()
                clipboard
                updates
                openAtLogin
                setupAgain
                if let notice = settings.notice {
                    Text(notice)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.busy)
                }
            }
            .padding(.top, Theme.Space.xs)
        }
        .scrollIndicators(.hidden)
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
            ThemePicker()
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
                Text("Arraste os cartões do Início e os tópicos da Conversa para reordenar.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Restaurar ordem dos tópicos") { settings.restoreTelegramOrder() }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                .disabled(settings.settings.telegramOrder.isEmpty)
            Button("Restaurar ordem do Início") { settings.restoreDashboardOrder() }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                .disabled(settings.settings.dashboardOrder == DashboardTileID.defaultOrder)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Avisos no notch

    private static let noticeKinds: [(NoticeKind, String)] = [
        (.reply, "Respostas"), (.telegram, "Telegram"), (.reminder, "Lembretes"), (.outbox, "Fila"), (.update, "Atualizações"),
    ]

    private var notices: some View {
        let current = settings.settings.notices
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    sectionTitle("Avisos no notch")
                    Text("O que acontece com o painel fechado desce do notch por alguns segundos. Clique para abrir.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Toggle("Não perturbe", isOn: Binding(
                    get: { current.doNotDisturb },
                    set: { on in settings.setNotices { $0.doNotDisturb = on } }
                ))
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
                .pointerStyle(.link)
            }
            HStack(spacing: Theme.Space.xl) {
                ForEach(Self.noticeKinds, id: \.0) { kind, label in
                    Toggle(label, isOn: Binding(
                        get: { current[kind] },
                        set: { on in settings.setNotices { $0[kind] = on } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .pointerStyle(.link)
                }
                Spacer(minLength: 0)
            }
            .disabled(current.doNotDisturb)
            .opacity(current.doNotDisturb ? 0.5 : 1)
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

    // MARK: Atualizações

    private var updates: some View {
        let updater = UpdateModel.shared
        return HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Atualizações")
                Text(updater.available.map { "Versão \(updater.version). A \($0) já está disponível." } ?? "Versão \(updater.version).")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(updater.available == nil ? "Verificar agora" : "Ver atualização") { updater.showUpdate() }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            Toggle("Verificar automaticamente", isOn: Binding(
                get: { updater.automaticChecks },
                set: { updater.setAutomaticChecks($0) }
            ))
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .font(Theme.Font.bodyMedium)
            .foregroundStyle(Theme.textPrimary)
            .pointerStyle(.link)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Abrir ao ligar o Mac

    private var openAtLogin: some View {
        let login = LoginItemModel.shared
        return HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Abrir ao ligar o Mac")
                Text(loginSentence(login))
                    .font(Theme.Font.caption)
                    .foregroundStyle(login.error == nil ? Theme.textSecondary : Theme.error)
            }
            Spacer()
            if login.installed, login.status == .requiresApproval {
                Button("Abrir Itens de Início") { login.openLoginItems() }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
            Toggle("Abrir ao ligar o Mac", isOn: Binding(
                get: { login.installed ? login.isOn : settings.settings.openAtLogin },
                set: { login.set($0) }
            ))
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .labelsHidden()
            .pointerStyle(.link)
            .disabled(!login.installed)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .onAppear { login.refresh() }
    }

    private func loginSentence(_ login: LoginItemModel) -> String {
        if let error = login.error { return error }
        guard login.installed else { return "Disponível quando o Wisp estiver em Aplicativos." }
        if login.removedByUser { return "Removido nos Ajustes do Sistema. Ligue de novo para o Wisp abrir sozinho." }
        return switch login.status {
        case .enabled: "O Wisp abre sozinho quando você entra no Mac."
        case .requiresApproval: "O macOS pede sua aprovação em Itens de Início para o Wisp abrir sozinho."
        case .notRegistered: "O Wisp não abre sozinho ao ligar o Mac."
        case .notFound: "O macOS não encontrou o Wisp para abrir ao ligar."
        }
    }

    // MARK: Setup

    private var setupAgain: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Setup")
                Text("Abre de novo o passo a passo que prepara o Wisp. O que já está pronto aparece marcado.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.Space.s) {
                Button("Rodar o setup de novo") { (NSApp.delegate as? AppDelegate)?.showSetup() }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                Button("Avisos de terceiros") {
                    for name in ["SwiftTerm-LICENSE", "Sparkle-LICENSE"] {
                        if let notice = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "ThirdParty") {
                            NSWorkspace.shared.open(notice)
                        }
                    }
                }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
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

struct ThemePicker: View {
    private let settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
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
