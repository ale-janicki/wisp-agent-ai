import SwiftUI
import WispCore

struct BrainTab: View {
    let profile: Profile
    var ask: (String, String) -> Bool
    private let model = BrainModel.shared
    @State private var asking = false
    @State private var showsHome = false
    @State private var graphQuery = Self.initialGraphQuery
    private let memory = MemoryModel.shared

    #if DEBUG
    static var snapshotGraphQuery = ""
    #endif

    private static var initialGraphQuery: String {
        #if DEBUG
        return snapshotGraphQuery
        #else
        return ""
        #endif
    }

    private var root: String? { profile.blocks?.memory?.root }

    private var vaultName: String? {
        root.map { (expandTilde($0) as NSString).lastPathComponent }
    }

    var body: some View {
        TabCard(title: "Brain", icon: PanelTab.brain.icon, trailing: vaultName, settingsTab: .brain) {
            ZStack {
                content
                overlays
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
        }
        .background { shortcuts }
        .onAppear {
            if let root {
                model.load(root: root)
                memory.refreshRecents(root: root)
            }
        }
        .onChange(of: model.activeID) { _, _ in showsHome = false }
        .onDisappear {
            model.flush()
            model.closeOverlays()
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let source = model.active?.path else { return .systemAction }
            return BrainLinkRouter.handle(url, source: source, model: model)
        })
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            SkeletonRows(count: 6)
        case .failed(let message):
            VStack(alignment: .leading) {
                InlineError(text: message)
                Spacer(minLength: 0)
            }
        case .ready:
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                toolbar
                if let message = model.message { InlineError(text: message) }
                if model.tabs.count > 1 { tabStrip }
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    if model.showsTree {
                        BrainTreeView(model: model)
                            .frame(width: 176)
                    }
                    main
                    if model.sidePanel != nil, let tab = model.active {
                        BrainSidePanelView(tab: tab, model: model)
                            .frame(width: 190)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var main: some View {
        if model.showsGraph, let root {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SearchField(text: $graphQuery, placeholder: "Buscar nota no grafo")
                    .padding(.horizontal, Theme.Space.s)
                MemoryGraphView(root: root, query: graphQuery, recent: model.active?.path ?? recentPath) { path in
                    model.showsGraph = false
                    showsHome = false
                    model.open(path)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showsHome || model.active == nil {
            BrainHomeView(block: profile.blocks?.memory) { path in
                showsHome = false
                model.open(path)
            } openDaily: {
                showsHome = false
                model.openDaily()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let tab = model.active {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(tab.title)
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Space.m)
                if let reason = tab.readOnly { InlineError(text: reason) }
                if let conflict = tab.conflict { ConflictBanner(conflict: conflict, model: model) }
                if tab.holdsMarkers {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Resolver conflitos: o texto tem marcadores de mesclagem e não será salvo até você removê-los.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Salvar mesmo assim") { model.saveDespiteMarkers() }.buttonStyle(CompactCapsuleStyle(accent: false))
                    }
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.error.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
                }
                noteBody(tab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var recentPath: String? {
        if case .loaded(let notes) = memory.recents { return notes.first?.path }
        return nil
    }

    @ViewBuilder
    private func noteBody(_ tab: BrainOpenNote) -> some View {
        if let failure = tab.failure {
            InlineError(text: failure)
        } else if tab.loading {
            SkeletonRows(count: 5)
        } else {
            switch tab.kind {
            case .note:
                if tab.editing {
                    BrainEditorView(id: tab.id, text: tab.text, revision: tab.revision, jumpLine: tab.jumpLine, jumpSeq: tab.jumpSeq, locked: tab.conflict != nil, model: model)
                        .id(tab.id)
                } else {
                    BrainReaderView(tab: tab, model: model)
                }
            case .drawing:
                if let url = model.url(for: tab.path) { BrainDrawingView(url: url, vaultRoot: model.root.map { URL(fileURLWithPath: $0) }, onOpenNote: { model.openFromDrawing($0, drawingPath: tab.path) }).padding(.horizontal, Theme.Space.m) }
            case .image:
                BrainEmbedView(embed: BrainEmbed(name: tab.path), source: tab.path, model: model, depth: 0).padding(.horizontal, Theme.Space.m)
            case .other:
                EmptyView()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            iconButton("sidebar.left", help: "Mostrar ou esconder a árvore", on: model.showsTree) { model.showsTree.toggle() }
            iconButton("chevron.left", help: "Voltar (⌘[)", enabled: model.active?.history.canGoBack == true) { model.goBack() }
            iconButton("chevron.right", help: "Avançar (⌘])", enabled: model.active?.history.canGoForward == true) { model.goForward() }
            Spacer(minLength: 0)
            iconButton("house", help: "Visão geral: recentes e busca", on: showsHome || (model.active == nil && !model.showsGraph)) {
                showsHome = model.showsGraph ? true : !showsHome
                model.showsGraph = false
            }
            if let tab = model.active, tab.kind == .note, !model.showsGraph, !showsHome {
                iconButton(tab.editing ? "book" : "pencil", help: tab.readOnly != nil ? "Somente leitura" : (tab.editing ? "Ler (⌘E)" : "Editar (⌘E)"), on: tab.editing, enabled: tab.readOnly == nil) { model.toggleEditing() }
                iconButton(model.bookmarks.contains(tab.path) ? "star.fill" : "star", help: "Favoritar", on: model.bookmarks.contains(tab.path)) { model.toggleBookmark(tab.path) }
                iconButton("sidebar.right", help: "Backlinks, links, tópicos e tags", on: model.sidePanel != nil) {
                    model.sidePanel = model.sidePanel == nil ? .backlinks : nil
                }
            }
            iconButton("magnifyingglass", help: "Buscar no texto (⇧⌘F)") { model.showsSearch = true }
            iconButton("circle.hexagongrid", help: "Grafo", on: model.showsGraph) { model.showsGraph.toggle() }
            Menu {
                Button("Ir para nota… (⌘O)") { model.showsSwitcher = true }
                Button("Nota de hoje (⇧⌘D)") { model.openDaily() }
                Menu("Inserir modelo") {
                    ForEach(model.templates, id: \.self) { path in
                        Button(BrainTree.displayName(path, isFolder: false)) { model.insertTemplate(path) }
                    }
                }
                .disabled(model.templates.isEmpty || model.active?.kind != .note)
                Divider()
                Button("Nova nota") { model.prompt = .newNote(folder: model.active.map { BrainText.parent(of: $0.path) } ?? "") }
                Button("Novo desenho") { model.createDrawing(.excalidraw, in: model.active.map { BrainText.parent(of: $0.path) } ?? "") }
                Button("Novo canvas") { model.createDrawing(.canvas, in: model.active.map { BrainText.parent(of: $0.path) } ?? "") }
                Button("Nova pasta") { model.prompt = .newFolder(folder: "") }
                Divider()
                Button("Adicionar propriedades à nota") { model.setProperty("tags", to: .list([])) }
                    .disabled(model.active?.kind != .note || BrainDocument(model.active?.text ?? "").hasFrontmatter)
                Button("Perguntar ao Wisp sobre esta nota…") { asking = true }
                    .disabled(model.active?.kind != .note)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 28, height: 28)
        }
    }

    private func iconButton(_ name: String, help: String, on: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name) }
            .buttonStyle(CircleButtonStyle(kind: on ? .accent : .plain, size: 28))
            .disabled(!enabled)
            .help(help)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(model.tabs) { tab in
                    HStack(spacing: 4) {
                        Button { model.activate(tab.id) } label: {
                            HStack(spacing: 4) {
                                if tab.dirty { Circle().fill(Theme.busy).frame(width: 5, height: 5) }
                                Text(tab.title).lineLimit(1).frame(maxWidth: 120)
                            }
                        }
                        .buttonStyle(.plain)
                        Button { model.close(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain)
                            .help("Fechar aba")
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(tab.id == model.activeID ? Theme.accentText : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(tab.id == model.activeID ? Theme.accentFill : Theme.surfaceHi.opacity(0.6)))
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 26)
    }

    @ViewBuilder
    private var overlays: some View {
        if model.showsSwitcher { BrainSwitcherOverlay(model: model) }
        if model.showsSearch { BrainSearchOverlay(model: model) }
        if let prompt = model.prompt { BrainPromptOverlay(model: model, prompt: prompt).id(prompt.id) }
        if asking, let tab = model.active {
            BrainAskOverlay(tab: tab, dismiss: { asking = false }) { question in
                let context = BrainAsk.context(path: tab.path, title: tab.title, text: tab.text)
                if ask(question, context) { asking = false } else { model.message = "Não consegui enviar a pergunta agora." }
            }
        }
    }

    private var shortcuts: some View {
        Group {
            Button("") { model.toggleEditing() }.keyboardShortcut("e", modifiers: .command)
            Button("") { model.showsSwitcher = true }.keyboardShortcut("o", modifiers: .command)
            Button("") { model.showsSearch = true }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("") { model.goBack() }.keyboardShortcut("[", modifiers: .command)
            Button("") { model.goForward() }.keyboardShortcut("]", modifiers: .command)
            Button("") { model.openDaily() }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("") { model.flushActive() }.keyboardShortcut("s", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

private struct ConflictBanner: View {
    let conflict: BrainConflict
    var model: BrainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conflict.kind == .deleted
                ? "Esta nota foi apagada ou movida fora do Wisp, e você tem texto que ainda não foi salvo."
                : "Esta nota mudou no disco (git, outro editor ou o agente) e você tem edições aqui.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if conflict.kind == .changed {
                    Button(conflict.hasMarkers ? "Mesclar com marcadores" : "Mesclar") { model.resolveConflict(.merge) }
                        .buttonStyle(CompactCapsuleStyle(accent: true))
                    Button("Usar a do disco") { model.resolveConflict(.useDisk) }
                        .buttonStyle(CompactCapsuleStyle(accent: false))
                }
                Button(conflict.kind == .deleted ? "Recriar com meu texto" : "Manter a minha") { model.resolveConflict(.keepMine) }
                    .buttonStyle(CompactCapsuleStyle(accent: false))
            }
            Text("O texto descartado fica guardado em Application Support/Wisp/brain-recuperado.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.busy.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
    }
}
