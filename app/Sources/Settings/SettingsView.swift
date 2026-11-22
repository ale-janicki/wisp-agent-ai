import AppKit
import SwiftUI
import WispCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, model, notices, integrations, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Aparência"
        case .model: "Modelo"
        case .notices: "Avisos"
        case .integrations: "Integrações"
        case .general: "Geral"
        case .about: "Sobre"
        }
    }

    var icon: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .model: "sparkles"
        case .notices: "bell.fill"
        case .integrations: "puzzlepiece.extension.fill"
        case .general: "gearshape.fill"
        case .about: "info.circle.fill"
        }
    }

    static func saved(_ id: String?) -> SettingsSection {
        SettingsSectionMigration.current(id).flatMap(SettingsSection.init(rawValue:)) ?? .appearance
    }

    @MainActor func open() {
        AppSettings.shared.setSettingsSection(rawValue)
    }
}

struct SettingsView: View {
    @ObservedObject var media: NowPlayingService
    private let settings = AppSettings.shared

    private static let repository = URL(string: "https://github.com/ale-janicki/wisp-agent-ai")!

    private var section: SettingsSection { .saved(settings.settings.settingsSection) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Ajustes")
                .font(Theme.Font.heading)
                .foregroundStyle(Theme.textPrimary)
            tabBar
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Layout.cardGap) {
                    pane
                    if let notice = settings.notice {
                        Text(notice)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.busy)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .id(section)
        }
        .padding(.top, Theme.Space.xs)
        .onAppear {
            NSColorPanel.shared.level = NSWindow.Level(rawValue: NotchPanel.windowLevel.rawValue + 1)
            media.refresh()
        }
        .onDisappear {
            if NSColorPanel.shared.isVisible { NSColorPanel.shared.close() }
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsSection.allCases) { tab in
                let selected = tab == section
                Button { tab.open() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                        Text(tab.title)
                            .font(Theme.Font.bodyMedium)
                            .foregroundStyle(selected ? Theme.accentText : Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(RowButtonStyle(highlight: selected ? .accent : .none))
                .fixedSize()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .appearance:
            colors
            order
        case .model:
            EngineSettingsCard()
            ModelPickerCard()
            PermissionSettingsCard()
        case .notices:
            notices
        case .integrations:
            IntegrationsPane(media: media)
        case .general:
            general
            meetings
            brain
            agenda
            macControl
            updates
        case .about:
            about
        }
    }

    // MARK: Aparência

    private var colors: some View {
        SettingsGroup(title: "Cores") {
            Button("Restaurar padrão") { settings.restoreDefaults() }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                .disabled(settings.settings.theme == WispSettings.default.theme && settings.settings.custom == nil)
        } content: {
            ThemePicker()
                .padding(.vertical, Theme.Space.xs)
        }
    }

    private var order: some View {
        SettingsGroup(title: "Ordem", caption: "Arraste os cartões do Início e os tópicos da Conversa para reordenar.") {
            SettingsRow(title: "Cartões do Início") {
                Button("Restaurar ordem") { settings.restoreDashboardOrder() }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    .disabled(settings.settings.dashboardOrder == DashboardTileID.defaultOrder)
            }
            Divider().overlay(Theme.stroke)
            SettingsRow(title: "Tópicos da Conversa") {
                Button("Restaurar ordem") { settings.restoreTelegramOrder() }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    .disabled(settings.settings.telegramOrder.isEmpty)
            }
        }
    }

    // MARK: Avisos

    private static let noticeKinds: [(NoticeKind, String)] = [
        (.reply, "Respostas"), (.telegram, "Telegram"), (.reminder, "Lembretes"), (.update, "Atualizações"),
        (.approval, "Aprovações"),
    ]

    private var notices: some View {
        let current = settings.settings.notices
        return SettingsGroup(
            title: "Avisos no notch",
            caption: "O que acontece com o painel fechado desce do notch por alguns segundos. Clique para abrir."
        ) {
            ToggleRow(
                title: "Não perturbe",
                detail: "Nenhum aviso desce do notch enquanto estiver ligado.",
                isOn: current.doNotDisturb
            ) { on in settings.setNotices { $0.doNotDisturb = on } }
            ForEach(Self.noticeKinds, id: \.0) { kind, label in
                Divider().overlay(Theme.stroke)
                ToggleRow(title: label, isOn: current[kind], enabled: !current.doNotDisturb) { on in
                    settings.setNotices { $0[kind] = on }
                }
            }
        }
    }

    // MARK: Geral

    private var general: some View {
        let login = LoginItemModel.shared
        return SettingsGroup(title: "Geral") {
            ToggleRow(
                title: "Abrir ao ligar o Mac",
                detail: loginSentence(login),
                detailColor: login.error == nil ? Theme.textSecondary : Theme.error,
                isOn: login.installed ? login.isOn : settings.settings.openAtLogin,
                enabled: login.installed
            ) { login.set($0) } accessory: {
                if login.installed, login.status == .requiresApproval {
                    Button("Abrir Itens de Início") { login.openLoginItems() }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            }
            Divider().overlay(Theme.stroke)
            ToggleRow(
                title: "Guardar copiados",
                detail: "Guarda o que você copia enquanto o Wisp roda. Senhas de gerenciadores nunca entram.",
                isOn: settings.settings.clipboardCapture
            ) { settings.setClipboardCapture($0) }
            Divider().overlay(Theme.stroke)
            PathRow(title: "Pasta do Wisp", key: .wispDir)
            Text("Trocar o caminho não move nada: aponta o Wisp para outra pasta.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(WispFolder.contents, id: \.name) { entry in
                    Text("\(entry.name): \(entry.detail)")
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, Theme.Space.s)
            MeetingsMoveRow()
            Divider().overlay(Theme.stroke)
            SettingsRow(
                title: "Setup",
                detail: "Abre de novo o passo a passo que prepara o Wisp. O que já está pronto aparece marcado."
            ) {
                Button("Rodar o setup de novo") { (NSApp.delegate as? AppDelegate)?.showSetup() }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
        }
        .onAppear {
            login.refresh()
            PathsModel.shared.refresh()
        }
    }

    private var meetings: some View {
        let current = settings.settings.meetings
        return SettingsGroup(
            title: "Reuniões",
            caption: "O áudio e a transcrição ficam no seu Mac. O webhook é opcional e só envia depois do seu clique."
        ) {
            SettingsRow(
                title: "Limite de gravação",
                detail: "Para sozinho depois desse tempo de gravação ativa, com um aviso 5 min antes. Pausas e o Mac dormindo não contam."
            ) {
                Picker("Limite de gravação", selection: Binding(
                    get: { current.limitMinutes },
                    set: { value in settings.setMeetings { $0.limitMinutes = value } }
                )) {
                    ForEach(MeetingSettings.limitChoices, id: \.self) { minutes in
                        Text(Self.limitLabel(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            Divider().overlay(Theme.stroke)
            ToggleRow(
                title: "Webhook ao terminar",
                detail: "Quando a nota ficar pronta, o Wisp mostra um cartão com o destino e o tamanho e só envia quando você clicar em Permitir. Vai a nota, as métricas e as ações, sem a transcrição.",
                isOn: current.webhookEnabled
            ) { on in settings.setMeetings { $0.webhookEnabled = on } }
            if current.webhookEnabled {
                WebhookURLField()
            }
        }
    }

    private static func limitLabel(_ minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes) min"
    }

    private var brain: some View {
        let model = BrainSettingsModel.shared
        return SettingsGroup(title: "Brain") {
            SettingsRow(
                title: "Pasta do brain",
                detail: model.profileIsLink ? "\(model.displayFolder)\nO perfil é gerenciado fora do Wisp: ajuste o caminho da memória nele." : model.displayFolder
            ) {
                Button("Alterar…") { model.chooseFolder() }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
            Divider().overlay(Theme.stroke)
            ToggleRow(
                title: "Aprender com as conversas",
                detail: "Depois de 30 min sem mensagens, o Wisp guarda no brain o que a conversa teve de importante. Usa o seu plano.",
                isOn: model.learns
            ) { model.setLearns($0) }
            Divider().overlay(Theme.stroke)
            lessons(model)
            if let error = model.error {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.error)
            }
        }
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private func lessons(_ model: BrainSettingsModel) -> some View {
        SettingsRow(
            title: "O que o Wisp aprendeu",
            detail: model.lessons.isEmpty
                ? "Quando você corrigir o Wisp ou disser como prefere as coisas, ele guarda aqui e passa a seguir em toda conversa."
                : "Preferências que o Wisp segue em toda conversa. Remover faz ele esquecer."
        ) { EmptyView() }
        ForEach(model.pendingLessons) { lesson in
            Divider().overlay(Theme.stroke)
            SettingsRow(
                title: lesson.rule,
                detail: "Quer aprender, esperando você confirmar" + (lesson.date.map { " · \($0)" } ?? "")
            ) {
                Button("Confirmar") { model.confirm(lesson) }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                Button("Descartar") { model.discard(lesson) }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
        }
        ForEach(model.lessons) { lesson in
            Divider().overlay(Theme.stroke)
            SettingsRow(
                title: lesson.rule,
                detail: [lesson.learnedAlone ? "aprendido sozinho" : lesson.origin, lesson.date].compactMap { $0 }.joined(separator: " · ")
            ) {
                Button("Remover") { model.forget(lesson) }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
        }
    }

    private var agenda: some View {
        let access = AgendaAccessModel.shared
        return SettingsGroup(title: "Agenda") {
            SettingsRow(title: "Agenda: permitir acesso", detail: access.sentence) {
                if access.state != .granted {
                    Button(access.state == .denied ? "Abrir Ajustes do Sistema" : "Permitir") {
                        if access.state == .denied {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        } else {
                            access.ask()
                        }
                    }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    .disabled(access.busy)
                }
            }
            Divider().overlay(Theme.stroke)
            ToggleRow(
                title: "Ocultar títulos nas notificações e na barra de menu",
                detail: "Mostra \"Reunião\" no lugar do título do evento.",
                isOn: AppSettings.shared.settings.agenda.hideTitlesInAlerts
            ) { on in AppSettings.shared.setAgenda { $0.hideTitlesInAlerts = on } }
        }
        .onAppear { access.refresh() }
    }

    private var macControl: some View {
        let access = MacControlAccessModel.shared
        return SettingsGroup(title: "Controle do Mac") {
            SettingsRow(title: "Controle do Mac: permitir", detail: access.sentence) {
                if !access.granted {
                    Button(access.buttonTitle) { access.ask() }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                        .disabled(access.busy)
                }
            }
            Divider().overlay(Theme.stroke)
            SettingsRow(title: access.accessibilityLine, detail: "Ler a janela, clicar, digitar e apertar teclas em qualquer app.") { EmptyView() }
            Divider().overlay(Theme.stroke)
            SettingsRow(title: access.automationLine, detail: "Abrir e controlar apps, como Música, Safari e Mail, por script.") { EmptyView() }
        }
        .onAppear { access.refresh() }
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

    private var updates: some View {
        let updater = UpdateModel.shared
        return SettingsGroup(title: "Atualizações") {
            SettingsRow(
                title: "Versão \(updater.version)",
                detail: updater.available.map { "A \($0) já está disponível." }
            ) {
                Button(updater.available == nil ? "Verificar agora" : "Ver atualização") { updater.showUpdate() }
                    .buttonStyle(CapsuleButtonStyle(kind: updater.available == nil ? .ghost : .accent))
            }
            Divider().overlay(Theme.stroke)
            ToggleRow(title: "Verificar automaticamente", isOn: updater.automaticChecks) { updater.setAutomaticChecks($0) }
        }
    }

    // MARK: Sobre

    private var about: some View {
        SettingsGroup(title: "Wisp") {
            SettingsRow(title: "Versão") {
                Text(UpdateModel.shared.version)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }
            Divider().overlay(Theme.stroke)
            SettingsRow(title: "Código", detail: "github.com/ale-janicki/wisp-agent-ai") {
                Button("Abrir no GitHub") { NSWorkspace.shared.open(Self.repository) }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
            Divider().overlay(Theme.stroke)
            SettingsRow(title: "Licença", detail: "Software livre: você pode usar, estudar, mudar e redistribuir.") {
                Text("GPL-3.0")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            Divider().overlay(Theme.stroke)
            SettingsRow(title: "Modelo de voz", detail: SpeechModelSpec.attribution) {
                Text("CC-BY-4.0")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            Divider().overlay(Theme.stroke)
            SettingsRow(title: "Avisos de terceiros", detail: "Licenças do SwiftTerm, do Sparkle e do FluidAudio, que vêm dentro do Wisp.") {
                Button("Abrir avisos") {
                    for name in ["SwiftTerm-LICENSE", "Sparkle-LICENSE", "FluidAudio-LICENSE"] {
                        if let notice = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "ThirdParty") {
                            NSWorkspace.shared.open(notice)
                        }
                    }
                }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
        }
    }
}

// MARK: Integrações

struct IntegrationsPane: View {
    enum Integration: CaseIterable { case spotify, music }

    @MainActor static var expandOnOpen: Integration?

    @ObservedObject var media: NowPlayingService
    private let spotify = SpotifyModel.shared
    @State private var open: Integration?

    private static let reflow = Animation.spring(response: 0.3, dampingFraction: 0.82)

    var body: some View {
        SettingsGroup(title: "Integrações") {
            ForEach(Array(Integration.allCases.enumerated()), id: \.element) { index, item in
                if index > 0 { Divider().overlay(Theme.stroke) }
                row(item)
            }
        }
        .onAppear {
            if let pending = Self.expandOnOpen {
                open = pending
                Self.expandOnOpen = nil
            }
        }
    }

    private func row(_ item: Integration) -> some View {
        let expanded = open == item
        let state = status(item)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Self.reflow) { open = expanded ? nil : item }
            } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: icon(item))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 20)
                    Text(name(item))
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: Theme.Space.s)
                    Circle().fill(state.color).frame(width: 6, height: 6)
                    Text(state.text)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .frame(minHeight: Theme.Layout.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(expanded ? .isSelected : [])
            if expanded {
                detail(item)
                    .padding(.leading, 20 + Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func detail(_ item: Integration) -> some View {
        switch item {
        case .spotify:
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                AutomationPromptView(media: media, player: .spotify, showsGranted: true)
                SpotifySettingsCard(embedded: true)
            }
        case .music:
            AutomationPromptView(media: media, player: .music, showsGranted: true)
        }
    }

    private func name(_ item: Integration) -> String {
        switch item {
        case .spotify: MediaPlayer.spotify.name
        case .music: MediaPlayer.music.name
        }
    }

    private func icon(_ item: Integration) -> String {
        switch item {
        case .spotify: "dot.radiowaves.left.and.right"
        case .music: "music.note"
        }
    }

    private func status(_ item: Integration) -> (text: String, color: Color) {
        switch item {
        case .spotify:
            switch media.automationStatus(for: .spotify) {
            case .denied, .notDetermined: return ("Sem permissão", Theme.error)
            case .granted, .notRunning: break
            }
            if spotify.auth == .signedIn { return ("Conectado", Theme.ok) }
            return spotify.hasClientID ? ("Não conectado", Theme.busy) : ("Não configurado", Theme.textTertiary)
        case .music:
            switch media.automationStatus(for: .music) {
            case .granted: return ("Conectado", Theme.ok)
            case .denied, .notDetermined: return ("Sem permissão", Theme.error)
            case .notRunning: return ("Não configurado", Theme.textTertiary)
            }
        }
    }
}

// MARK: Rows

private struct SettingsGroup<Trailing: View, Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.textPrimary)
                    if let caption {
                        Text(caption)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                trailing
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

extension SettingsGroup where Trailing == EmptyView {
    init(title: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, caption: caption, trailing: { EmptyView() }, content: content)
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            RowLabel(title: title, detail: detail)
            Spacer(minLength: Theme.Space.s)
            control
        }
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: Theme.Layout.rowHeight)
    }
}

private struct MeetingsMoveRow: View {
    private let model = PathsModel.shared
    @State private var recording = false

    var body: some View {
        Group {
            if model.pendingMeetings > 0 || model.meetingsMove != .idle {
                SettingsRow(title: "Mover reuniões", detail: recording ? "Espere a gravação terminar para mover." : detail) {
                    if case .moving = model.meetingsMove {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Mover reuniões") { model.moveMeetings() }
                            .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                            .disabled(model.pendingMeetings == 0 || recording)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                let roots = model.recordingRoots()
                recording = await Task.detached { PathsModel.recordingActive(in: roots) }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var detail: String {
        switch model.meetingsMove {
        case .moving(let done, let total): "Movendo \(done) de \(total)…"
        case .finished(let summary): summary
        case .failed(let message): "\(message) Dá para tentar de novo: o que já foi movido fica."
        case .idle: "\(model.pendingMeetings) reuniões ficaram em ~/Wisp/reunioes. Mover leva as gravações para a pasta nova."
        }
    }
}

private struct WebhookURLField: View {
    private let settings = AppSettings.shared
    @State private var draft = ""

    private var problem: String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        do {
            _ = try MeetingWebhook.validate(text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            TextField("", text: $draft, prompt: Text("https://…").foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(Theme.Font.tool)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Theme.surfaceHi, in: Capsule())
                .onChange(of: draft) { _, text in settings.setMeetings { $0.webhookURL = text.trimmingCharacters(in: .whitespacesAndNewlines) } }
            Text(problem ?? "Só https e só endereços públicos: localhost, IPs privados e redes locais são recusados.")
                .font(Theme.Font.caption)
                .foregroundStyle(problem == nil ? Theme.textSecondary : Theme.error)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Theme.Space.s)
        .onAppear { draft = settings.settings.meetings.webhookURL }
    }
}

private struct PathRow: View {
    let title: String
    let key: PathsModel.Key
    private let model = PathsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SettingsRow(title: title, detail: detail) {
                HStack(spacing: Theme.Space.s) {
                    Button("Trocar…") { model.choose(key) }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                        .disabled(model.busy)
                    Button("Mostrar no Finder") { model.reveal(key) }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                        .disabled(!FileManager.default.fileExists(atPath: model.url(key).path))
                }
            }
            if let error = model.errors[key] {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.error)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private var detail: String {
        let path = model.path(key)
        return path.isDefault ? "\(path.text) (padrão)" : path.text
    }
}

private struct ToggleRow<Accessory: View>: View {
    let title: String
    var detail: String?
    var detailColor = Theme.textSecondary
    let isOn: Bool
    var enabled = true
    let set: @MainActor (Bool) -> Void
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            RowLabel(title: title, detail: detail, detailColor: detailColor, dimmed: !enabled)
            Spacer(minLength: Theme.Space.s)
            accessory
            Toggle(title, isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accent)
                .labelsHidden()
                .allowsHitTesting(false)
                .disabled(!enabled)
        }
        .padding(.vertical, Theme.Space.s)
        .frame(minHeight: Theme.Layout.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { set(!isOn) } }
        .pointerStyle(enabled ? .link : nil)
    }
}

extension ToggleRow where Accessory == EmptyView {
    init(title: String, detail: String? = nil, detailColor: Color = Theme.textSecondary, isOn: Bool, enabled: Bool = true,
         set: @escaping @MainActor (Bool) -> Void) {
        self.init(title: title, detail: detail, detailColor: detailColor, isOn: isOn, enabled: enabled, set: set) { EmptyView() }
    }
}

private struct RowLabel: View {
    let title: String
    var detail: String?
    var detailColor = Theme.textSecondary
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(dimmed ? Theme.textTertiary : Theme.textPrimary)
            if let detail {
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
