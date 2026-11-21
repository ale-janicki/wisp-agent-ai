import AppKit
import SwiftUI
import WispCore

extension SetupStepID {
    var title: String {
        switch self {
        case .system: "O seu Mac"
        case .login: "Entrar no Claude"
        case .brain: "O seu cérebro"
        case .harness: "Ferramentas do Claude"
        case .telegram: "Telegram"
        case .spotify: "Spotify"
        case .profile: "Teu wisp"
        case .done: "Pronto"
        }
    }

    var intro: String {
        switch self {
        case .system: "O Wisp confere o seu Mac e instala o que faltar para o Claude funcionar."
        case .login: "Aqui você entra na sua conta do Claude."
        case .brain: "O cérebro é a pasta onde o Wisp guarda suas notas e lembranças."
        case .harness: "O Wisp instala as ferramentas que ensinam o Claude a usar o seu cérebro."
        case .telegram: "Conecte um bot do Telegram para conversar com o Wisp pelo celular, ou pule por enquanto."
        case .spotify: "Cole o Client ID do seu app no Spotify para ver e controlar a música."
        case .profile: "Dê um nome ao seu Wisp e escolha como ele aparece."
        case .done: "O Wisp está pronto para usar."
        }
    }
}

/// A runtime failure as one plain sentence plus the raw line for "detalhes".
enum RuntimeFailure {
    static func describe(_ text: String) -> (sentence: String, detail: String?) {
        let lower = text.lowercased()
        if text == RuntimeSync.lockFailure { return (text, nil) }
        let markers = [
            "dns", "network", "offline", "internet", "connection", "connect", "resolve", "lookup", "timed out",
            "error sending request", "failed to fetch", "failed to download", "tcp",
        ]
        if markers.contains(where: lower.contains) { return ("Sem internet — conecte e tente de novo", text) }
        return ("Não deu para preparar o Wisp", text)
    }
}

struct SetupView: View {
    let session: SetupSession
    let finish: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 268)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            Group {
                if let model = session.model {
                    StepPane(model: model, finish: finish)
                        .id(model.current)
                } else {
                    PreparingPane(runtime: session.runtime, retry: session.retryRuntime)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 820, height: 600)
        .background(Theme.bg)
        .onChange(of: session.runtime.phase, initial: true) { _, phase in session.adopt(phase) }
    }

    // MARK: Left column

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                WispAvatar(size: 28, animates: false)
                Text("Configurar o Wisp")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.bottom, Theme.Space.m)
            SidebarRow(title: "Preparando o Wisp", state: prepareState, selected: session.model == nil, action: nil)
            ForEach(SetupStepID.allCases, id: \.self) { step in
                let state = session.model?.row(step).state ?? .pending
                SidebarRow(
                    title: step.title, state: state, selected: session.model?.current == step,
                    action: session.model.map { model in { model.current = step } })
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.l)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var prepareState: SetupModel.RowState {
        switch session.runtime.phase {
        case .checking, .installing: .running
        case .ready: .done
        case .failed(let text): .failed(RuntimeFailure.describe(text).sentence)
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let state: SetupModel.RowState
    let selected: Bool
    let action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let content = HStack(spacing: Theme.Space.s) {
            icon.frame(width: 18)
            Text(title)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if state == .skipped {
                Text("pulado")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: Theme.Layout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous)
                .fill(selected ? Theme.accentFill : (hovering && action != nil ? Theme.highlight : .clear))
        )
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .pointerStyle(.link)
        } else {
            content
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending: Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.5).frame(width: 10, height: 10)
        case .running: ProgressView().controlSize(.small).scaleEffect(0.7)
        case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ok)
        case .skipped: Image(systemName: "minus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
        case .needsUser, .failed: Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.busy)
        }
    }
}

// MARK: Runtime

private struct PreparingPane: View {
    let runtime: RuntimeInstaller
    let retry: () -> Void
    @State private var detailsOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Preparando o Wisp")
                .font(Theme.Font.heading)
                .foregroundStyle(Theme.textPrimary)
            switch runtime.phase {
            case .checking:
                working("Conferindo o que já está instalado")
            case .installing(let label):
                working(label)
            case .ready:
                working("Pronto")
            case .failed(let text):
                let failure = RuntimeFailure.describe(text)
                Text(failure.sentence)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.busy)
                Button("Tentar de novo", action: retry)
                    .buttonStyle(CapsuleButtonStyle())
                if let raw = failure.detail {
                    StepDetailsView(
                        row: SetupModel.StepRow(
                            id: .system, report: SetupReport(step: "runtime", status: .failed, summary: failure.sentence,
                                details: [SetupDetail(command: "preparar o Wisp", exit: 1, output: raw)])),
                        open: $detailsOpen)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func working(_ label: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: Steps

private struct StepPane: View {
    @Bindable var model: SetupModel
    let finish: () -> Void

    private var step: SetupStepID { model.current }
    private var row: SetupModel.StepRow { model.row(step) }
    private var discoverFailed: Bool {
        if case .failed = row.state { return true }
        return false
    }
    private var settled: Bool { row.state == .done || row.state == .skipped }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(step.title)
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.textPrimary)
                Text(step.intro)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                stepBody
                status
                actions
                StepDetailsView(row: row, open: $model.detailsOpen)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.xl)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Per step

    @ViewBuilder private var stepBody: some View {
        switch step {
        case .system:
            if !settled {
                Toggle("instalar Homebrew (opcional)", isOn: $model.withHomebrew)
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .pointerStyle(.link)
            }
        case .login:
            LoginStepView(model: model)
        case .brain:
            brainFolder
        case .harness:
            harnessResult
        case .telegram:
            if !model.telegramTokenStored, !model.telegramConfigured, !settled {
                tokenField
            }
        case .spotify:
            SpotifySettingsCard()
        case .profile:
            ProfileStepView(model: model)
        case .done:
            leftForLater
        }
    }

    private var brainFolder: some View {
        let folder = model.brainFolder ?? model.defaultBrainFolder
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Text(displayPath(folder))
                    .font(Theme.Font.tool)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceHi, in: Capsule())
                if !settled {
                    Button("Escolher outra pasta…") { chooseBrainFolder() }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            }
            if let warning = row.report?.data["warning"] {
                Text(Self.sentence(warning))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.busy)
            }
        }
    }

    @ViewBuilder private var harnessResult: some View {
        if let data = row.report?.data {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if let backup = data["backup"], !backup.isEmpty {
                    Text("Cópia de segurança do seu .claude em \(displayPath(URL(fileURLWithPath: backup))).")
                }
                if let conflicts = data["conflicts"], let count = Int(conflicts), count > 0 {
                    Text(count == 1 ? "1 arquivo que você editou foi mantido." : "\(count) arquivos que você editou foram mantidos.")
                        .foregroundStyle(Theme.busy)
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Token do bot (criado no BotFather)")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            SecureField("", text: $model.telegramToken, prompt: Text("cole o token aqui").foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(Theme.Font.tool)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Theme.surfaceHi, in: Capsule())
        }
    }

    @ViewBuilder private var leftForLater: some View {
        let later = model.rows.filter { $0.state == .skipped }.map(\.id.title)
        if !later.isEmpty {
            Text("Ficou para depois: \(later.joined(separator: ", ")).")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        switch row.state {
        case .running:
            HStack(spacing: Theme.Space.m) {
                ProgressView().controlSize(.small)
                Text(runningLabel)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .needsUser(let text):
            HStack(alignment: .top, spacing: Theme.Space.s) {
                if step == .system, !model.pollTimedOut { ProgressView().controlSize(.small) }
                Text(Self.sentence(text))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.busy)
            }
        case .failed(let text):
            Text(Self.sentence(text))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.error)
        case .done, .skipped:
            if let summary = row.report?.summary {
                Label(Self.sentence(summary), systemImage: "checkmark")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.ok)
            }
        case .pending:
            EmptyView()
        }
    }

    /// The group search waits for her 'oi', so it says so instead of a generic "working".
    private var runningLabel: String {
        if step == .telegram, row.command.contains("--discover"), !model.telegramConfigured {
            return "Mande 'oi' no grupo agora — estou procurando"
        }
        return "Trabalhando…"
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        HStack(spacing: Theme.Space.m) {
            if settled, step != .done {
                Button("Continuar") { model.advance() }
                    .buttonStyle(CapsuleButtonStyle())
                if step == .telegram, model.telegramConfigured { disconnectTelegram }
            } else {
                primary
                secondary
            }
        }
    }

    @ViewBuilder private var primary: some View {
        switch step {
        case .system:
            if model.doctorFailed {
                run("Conferir de novo") { await model.verifySystem() }
            } else if model.pollTimedOut {
                run("verificar") { await model.verifySystem() }
            } else {
                run("Preparar o Mac") { await model.run(.system, arguments: model.withHomebrew ? ["--with-homebrew"] : []) }
            }
        case .login:
            Button("Pular por enquanto") { model.skip(.login) }
                .buttonStyle(CapsuleButtonStyle())
        case .brain:
            run("Criar o cérebro") {
                await model.run(.brain, arguments: model.brainFolder.map { ["--path", $0.path] } ?? [])
            }
        case .harness:
            run("Instalar as ferramentas") { await model.run(.harness) }
        case .telegram:
            if model.telegramConfigured {
                run("Conferir o bot") { await model.run(.telegram, arguments: ["--discover"]) }
            } else if model.telegramTokenStored {
                run(discoverFailed ? "Procurar o grupo de novo" : "Procurar o grupo") {
                    await model.run(.telegram, arguments: ["--discover"])
                }
            } else {
                let text = model.telegramToken.trimmingCharacters(in: .whitespacesAndNewlines)
                run("Conectar o bot", disabled: text.isEmpty) {
                    model.telegramToken = ""
                    await model.run(.telegram, arguments: ["--token-stdin"], stdin: Data(text.utf8))
                }
            }
        case .spotify:
            if !AppSettings.shared.settings.spotifyClientID.isEmpty {
                Button("Continuar") { model.markDone(.spotify); model.advance() }
                    .buttonStyle(CapsuleButtonStyle())
            }
        case .profile:
            run("Salvar o meu Wisp", disabled: model.profileName.trimmingCharacters(in: .whitespaces).isEmpty
                || model.profileUserName.trimmingCharacters(in: .whitespaces).isEmpty) {
                var arguments = ["--name", model.profileName, "--user-name", model.profileUserName]
                if let avatar = model.profileAvatar { arguments += ["--avatar", avatar.path] }
                await model.run(.profile, arguments: arguments)
            }
        case .done:
            Button("Começar") { model.finish(); finish() }
                .buttonStyle(CapsuleButtonStyle())
        }
    }

    @ViewBuilder private var secondary: some View {
        switch step {
        case .telegram:
            if model.telegramConfigured {
                disconnectTelegram
            } else {
                Button("pular") { Task { await model.run(.telegram, arguments: ["--skip"]) } }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    .disabled(model.isBusy)
            }
        case .spotify:
            Button("pular") { model.skip(.spotify) }
                .buttonStyle(CapsuleButtonStyle(kind: .ghost))
        default:
            EmptyView()
        }
    }

    /// `wisp setup telegram --skip` on a configured setup removes the bot job, wisp.json's telegram and the profile block.
    private var disconnectTelegram: some View {
        Button("desconectar o Telegram") { Task { await model.run(.telegram, arguments: ["--skip"]) } }
            .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            .disabled(model.isBusy)
    }

    private func run(_ title: String, disabled: Bool = false, _ work: @escaping () async -> Void) -> some View {
        Button(title) { Task { await work() } }
            .buttonStyle(CapsuleButtonStyle())
            .disabled(disabled || model.isBusy)
    }

    // MARK: Helpers

    /// The CLI's lowercase summaries as a sentence: capital first, full stop last.
    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        let capitalized = first.uppercased() + text.dropFirst()
        return capitalized.hasSuffix(".") || capitalized.hasSuffix("?") ? capitalized : capitalized + "."
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = model.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseBrainFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Escolher"
        panel.message = "Escolha a pasta do seu cérebro"
        panel.directoryURL = model.home
        if panel.runModal() == .OK { model.brainFolder = panel.url }
    }
}
