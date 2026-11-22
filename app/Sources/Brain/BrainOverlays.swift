import SwiftUI
import WispCore

struct BrainOverlayCard<Content: View>: View {
    let dismiss: () -> Void
    var width: CGFloat = 420
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            content
                .padding(Theme.Space.m)
                .frame(width: width)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1) }
                .shadow(color: Theme.notch.opacity(0.4), radius: 16, y: 8)
                .padding(.top, 36)
        }
        .transition(.opacity)
    }
}

struct BrainSwitcherOverlay: View {
    var model: BrainModel
    @State private var query = ""
    @State private var selection = 0

    private var results: [BrainSwitcherResult] { model.switcherResults(query) }

    var body: some View {
        BrainOverlayCard(dismiss: { model.showsSwitcher = false }) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SearchField(text: $query, placeholder: "Ir para uma nota (título, apelido ou caminho)", autofocus: true)
                    .onSubmit { choose(selection) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                let shown = results
                if shown.isEmpty {
                    Text("Nenhuma nota").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(Theme.Space.s)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, result in
                                Button { choose(index) } label: {
                                    HStack(spacing: Theme.Space.s) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(result.title).font(Theme.Font.bodyMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                            Text(result.alias.map { "apelido: \($0)" } ?? BrainText.parent(of: result.path))
                                                .font(Theme.Font.caption)
                                                .foregroundStyle(Theme.textTertiary)
                                                .lineLimit(1)
                                                .truncationMode(.head)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(RowButtonStyle(highlight: index == selection ? .subtle : .none, height: 38))
                                .id(index)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    .scrollIndicators(.hidden)
                    .onChange(of: selection) { _, value in proxy.scrollTo(value) }
                }
            }
        }
        .onChange(of: query) { selection = 0 }
    }

    private func choose(_ index: Int) {
        let list = results
        guard list.indices.contains(index) else { return }
        model.showsSwitcher = false
        model.open(list[index].path, newTab: NSEvent.modifierFlags.contains(.command))
    }
}

struct BrainSearchOverlay: View {
    @Bindable var model: BrainModel
    @State private var selection = 0

    var body: some View {
        BrainOverlayCard(dismiss: { model.showsSearch = false }, width: 520) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SearchField(text: $model.searchQuery, placeholder: "Buscar em todas as notas", autofocus: true)
                    .onSubmit { choose(selection) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(model.searchHits.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                if let error = model.searchError {
                    InlineError(text: error)
                } else if model.searching {
                    SkeletonRows(count: 3)
                } else if model.searchHits.isEmpty, !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Nenhuma nota com “\(model.searchQuery)”").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(Theme.Space.s)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.searchHits.enumerated()), id: \.element.id) { index, hit in
                            Button { choose(index) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: Theme.Space.s) {
                                        Text(hit.title).font(Theme.Font.bodyMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                        Text(BrainText.parent(of: hit.path))
                                            .font(Theme.Font.caption)
                                            .foregroundStyle(Theme.textTertiary)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                            .layoutPriority(-1)
                                    }
                                    Text(hit.snippet).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(2).multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(RowButtonStyle(highlight: index == selection ? .subtle : .none, height: 52))
                        }
                    }
                }
                .frame(maxHeight: 300)
                .scrollIndicators(.hidden)
            }
        }
        .onAppear { model.search(model.searchQuery) }
        .onChange(of: model.searchQuery) {
            selection = 0
            model.search(model.searchQuery)
        }
    }

    private func choose(_ index: Int) {
        guard model.searchHits.indices.contains(index) else { return }
        model.showsSearch = false
        model.open(model.searchHits[index].path)
    }
}

struct BrainPromptOverlay: View {
    var model: BrainModel
    let prompt: BrainPrompt
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        BrainOverlayCard(dismiss: { model.prompt = nil }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                switch prompt {
                case .newNote(let folder):
                    field(title: "Nova nota" + (folder.isEmpty ? "" : " em \(folder)"), placeholder: "Nome da nota") {
                        model.prompt = nil
                        model.createNote(named: text, in: folder)
                    }
                case .newFolder(let folder):
                    field(title: "Nova pasta" + (folder.isEmpty ? "" : " em \(folder)"), placeholder: "Nome da pasta") {
                        model.prompt = nil
                        model.createFolder(named: text, in: folder)
                    }
                case .rename(let path, let isFolder):
                    field(title: isFolder ? "Renomear ou mover a pasta" : "Renomear ou mover a nota", placeholder: "pasta/nome", initial: Self.editable(path)) {
                        let clean = text.trimmingCharacters(in: .whitespaces)
                        let target = BrainFileKind.of(path) == .note && !clean.lowercased().hasSuffix(".md") ? clean + ".md" : clean
                        model.planMove(from: path, to: target)
                    }
                    Text("Mudar a parte da pasta move o item. Os [[links]] que apontam para ele são atualizados em todo o brain.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                case .missing(let name, let source):
                    Text("A nota “\(name)” ainda não existe").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                    Text("Criar em \(BrainText.parent(of: source).isEmpty ? "raiz do brain" : BrainText.parent(of: source))?")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                    buttons(confirm: "Criar nota") {
                        model.prompt = nil
                        model.createMissing(name: name, from: source)
                    }
                case .delete(let path, let isFolder):
                    Text("Mover para o Lixo?").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                    Text("“\(path)”\(isFolder ? " e tudo dentro dela" : "") vai para o Lixo do Mac; dá para recuperar de lá. Links que apontavam para ele ficam sem destino.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                    buttons(confirm: "Mover para o Lixo") { model.trash(path) }
                case .link(let url):
                    Text("Abrir este link?").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                    Text(url.absoluteString).font(Theme.Font.tool).foregroundStyle(Theme.textSecondary).textSelection(.enabled).lineLimit(4)
                    buttons(confirm: "Abrir") {
                        model.prompt = nil
                        NSWorkspace.shared.open(url)
                    }
                case .move(let plan):
                    Text("Atualizar os links").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                    Text("Mover “\(plan.from)” para “\(plan.to)” muda \(plan.linkCount) \(plan.linkCount == 1 ? "link" : "links") em \(plan.fileCount) \(plan.fileCount == 1 ? "nota" : "notas"). Tudo é aplicado de uma vez ou nada muda.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                    Text("Para desfazer, use o histórico do git do brain.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                    if !plan.undownloaded.isEmpty {
                        Text("\(plan.undownloaded.count) notas não verificadas (não baixadas do iCloud): links nelas podem não ser atualizados.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.busy)
                    }
                    if !plan.skipped.isEmpty {
                        Text("\(plan.skipped.count) notas não verificadas (link simbólico ou texto ilegível): \(plan.skipped.prefix(3).joined(separator: ", "))")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.busy)
                    }
                    buttons(confirm: "Mover e atualizar") { model.apply(plan) }
                }
            }
        }
    }

    private static func editable(_ path: String) -> String {
        BrainFileKind.of(path) == .note ? BrainText.withoutMarkdownSuffix(path) : path
    }

    private func field(title: String, placeholder: String, initial: String = "", confirm: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.Space.m)
                .frame(height: 30)
                .background(Capsule().fill(Theme.surfaceHi))
                .focused($focused)
                .onSubmit(confirm)
                .onAppear {
                    if text.isEmpty { text = initial }
                    focused = true
                }
            buttons(confirm: "Confirmar", action: confirm)
        }
    }

    private func buttons(confirm: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer(minLength: 0)
            Button("Cancelar") { model.prompt = nil }.buttonStyle(CapsuleButtonStyle(kind: .ghost))
            Button(confirm, action: action).buttonStyle(CapsuleButtonStyle(kind: .accent))
        }
    }
}

struct BrainAskOverlay: View {
    let tab: BrainOpenNote
    let dismiss: () -> Void
    let send: (String) -> Void
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        BrainOverlayCard(dismiss: dismiss, width: 460) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Perguntar ao Wisp sobre esta nota").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                Text("A nota “\(tab.title)” vai junto como contexto na conversa atual.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                TextField("", text: $question, prompt: Text("O que você quer saber?").foregroundStyle(Theme.textTertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...4)
                    .padding(Theme.Space.m)
                    .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
                    .focused($focused)
                    .onSubmit(submit)
                HStack {
                    Spacer(minLength: 0)
                    Button("Cancelar", action: dismiss).buttonStyle(CapsuleButtonStyle(kind: .ghost))
                    Button("Enviar", action: submit).buttonStyle(CapsuleButtonStyle(kind: .accent)).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(trimmed)
    }
}
