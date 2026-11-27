import AppKit
import Observation
import os
import WispCore

@MainActor
final class TerminalPaneView: NSView {
    private static let inputInsetLeading: CGFloat = 15
    private static let inputInsetTrailing: CGFloat = 12
    private static let inputInsetVertical: CGFloat = 8
    private static let maxEditorFraction: CGFloat = 0.4

    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "terminal-pane")
    private static let sessionOwners = NSMapTable<TerminalSession, NSUUID>.weakToStrongObjects()
    private static let engineOwners = NSMapTable<SwiftTermEngine, NSUUID>.weakToStrongObjects()

    let paneID = UUID()
    let list = BlockListView(frame: .zero)
    private let chipsView = ContextChipsView()
    private let editorScroll = NSScrollView()
    let editor = InputEditorView()
    private let completionMenu = CompletionMenuView()
    private let gridHint = NSTextField(labelWithString: "")
    private var hintGeneration = 0
    private weak var engine: SwiftTermEngine?
    private weak var session: TerminalSession?
    private var showsGrid = false
    private var modeApplied = false
    private var gitStatus: GitStatus?
    private var chipsDirectory: String?
    private var chipsFinishedID: Int?
    private var chipsGeneration = 0
    private var waitingForAnswer = false
    private var renderedChipsColors: ThemeColors?
    private var shellPath: String?
    private var resolvingShellPath = false
    private var lastShellPathAttempt: Date?
    private var unreadableHistoryFile: String?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(list)
        list.onRerun = { [weak self] command in self?.session?.submit(command) ?? false }
        list.onFocusEditor = { [weak self] event in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.editor)
            if let event { self.editor.keyDown(with: event) }
        }
        addSubview(chipsView)
        editorScroll.documentView = editor
        editorScroll.drawsBackground = false
        editorScroll.hasVerticalScroller = false
        editorScroll.hasHorizontalScroller = false
        editorScroll.borderType = .noBorder
        addSubview(editorScroll)
        editor.autoresizingMask = [.width]
        editor.onSubmit = { [weak self] text in
            guard self?.session?.submit(text) == true else { return false }
            CommandHistory.shared.append(text)
            return true
        }
        editor.onClear = { [weak self] in self?.clearBlocks() }
        editor.onSearchChange = { [weak self] in self?.syncCompletionMenu() }
        editor.isProgram = { [weak self] word in self?.isProgram(word) ?? true }
        editor.isProgramPrefix = { [weak self] word in self?.isProgramPrefix(word) ?? true }
        editor.onKey = { [weak self] key, control in self?.session?.sendKeys(key, control: control) }
        editor.onPaste = { [weak self] text in self?.session?.paste(text) }
        editor.onHeightChange = { [weak self] in self?.needsLayout = true }
        editor.completionProvider = { [weak self] line, cursor in self?.completions(line: line, cursor: cursor) ?? [] }
        editor.onCompletionsChange = { [weak self] in self?.syncCompletionMenu() }
        completionMenu.isHidden = true
        completionMenu.onPick = { [weak self] index in
            if self?.editor.isSearchingHistory == true { self?.editor.acceptHistoryResult(index) } else { self?.editor.acceptCompletion(index) }
            self?.focus()
        }
        addSubview(completionMenu)
        gridHint.font = .systemFont(ofSize: 11, weight: .medium)
        gridHint.wantsLayer = true
        gridHint.layer?.cornerRadius = 6
        gridHint.isHidden = true
        gridHint.alphaValue = 0
        gridHint.stringValue = Self.gridHintText
        addSubview(gridHint)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Wiring

    func attach(engine: SwiftTermEngine, session: TerminalSession) {
        if self.engine !== engine || self.session !== session { detach() }
        self.engine = engine
        self.session = session
        let grid = engine.view
        if grid.superview !== self {
            grid.removeFromSuperview()
            grid.frame = bounds
            addSubview(grid, positioned: .below, relativeTo: nil)
        }
        resolveShellPath()
        seedHistory(session)
        Self.sessionOwners.setObject(paneID as NSUUID, forKey: session)
        Self.engineOwners.setObject(paneID as NSUUID, forKey: engine)
        Self.log.debug("attach pane \(self.paneID.uuidString, privacy: .public)")
        session.onBlocksChanged = { [weak self] in self?.refresh() }
        engine.onViewportChange = { [weak self] in self?.refreshLive() }
        observeTheme()
        refresh()
    }

    private var observingTheme = false

    private func observeTheme() {
        guard !observingTheme else { return }
        observingTheme = true
        withObservationTracking {
            _ = AppSettings.shared.colors
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.themeChanged() } }
        }
    }

    private func themeChanged() {
        observingTheme = false
        guard let engine else { return }
        engine.applyTheme(colors, fontSize: engine.view.font.pointSize)
        refresh()
        observeTheme()
    }

    func detach() {
        editor.closeCompletions()
        editor.closeHistorySearch()
        let id = paneID.uuidString
        if let session {
            let owns = Self.sessionOwners.object(forKey: session) as UUID? == paneID
            if owns {
                session.onBlocksChanged = nil
                Self.sessionOwners.removeObject(forKey: session)
            }
            Self.log.debug("detach pane \(id, privacy: .public) session callbacks \(owns ? "cleared" : "skipped: another pane owns them", privacy: .public)")
        }
        if let engine {
            let owns = Self.engineOwners.object(forKey: engine) as UUID? == paneID
            if owns {
                engine.onViewportChange = nil
                Self.engineOwners.removeObject(forKey: engine)
            }
            Self.log.debug("detach pane \(id, privacy: .public) engine callbacks \(owns ? "cleared" : "skipped: another pane owns them", privacy: .public)")
        }
        if let grid = engine?.view, grid.superview === self { grid.removeFromSuperview() }
        list.reset()
        session = nil
        engine = nil
        showsGrid = false
        modeApplied = false
        renderedChipsColors = nil
        chipsDirectory = nil
        chipsFinishedID = nil
        gitStatus = nil
        chipsGeneration += 1
    }

    func focus() {
        guard let window, let engine else { return }
        window.makeFirstResponder(showsGrid ? engine.view : editor)
    }

    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !showsGrid, hasFocus, list.handleKeyEquivalent(event, fromEditor: window?.firstResponder === editor) { return true }
        if hasFocus, event.type == .keyDown, event.keyCode == 5,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == [.command, .shift] {
            session?.toggleGrid()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Refresh

    private var font: NSFont { engine?.view.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }
    private var colors: ThemeColors { AppSettings.shared.colors }

    func refresh() {
        guard let session, engine != nil else { return }
        seedHistory(session)
        applyMode(session.mode)
        syncEditor(session)
        syncChips(session)
        refreshLive()
        needsLayout = true
    }

    func refreshLive() {
        guard let session, let engine, !showsGrid else { return }
        updateWaiting(session, engine: engine)
        let blocks = session.blocks.blocks
        let live = session.blocks.running.map { _ in engine.liveOutput(from: 0) }
        list.update(blocks: blocks, live: live, font: font, colors: colors)
    }

    private func applyMode(_ mode: PaneMode) {
        guard let engine else { return }
        let grid = mode.isGrid
        guard !modeApplied || grid != showsGrid else { return }
        modeApplied = true
        let hadFocus = hasFocus
        showsGrid = grid
        if grid { editor.closeCompletions() }
        engine.view.isHidden = !grid
        list.isHidden = grid
        chipsView.isHidden = grid
        editorScroll.isHidden = grid
        if grid {
            engine.view.needsDisplay = true
        } else {
            list.scrollToBottom()
        }
        if hadFocus { focus() }
        if mode == .grid(.manual) { flashGridHint() } else { hideGridHint() }
    }

    static let gridHintText = "⇧⌘G volta aos blocos"

    private func flashGridHint() {
        hintGeneration += 1
        let mine = hintGeneration
        gridHint.textColor = TerminalTheme.ns(colors.textSecondary)
        gridHint.layer?.backgroundColor = TerminalTheme.ns(colors.surface).withAlphaComponent(0.85).cgColor
        gridHint.isHidden = false
        gridHint.alphaValue = 1
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gridHintDuration) { [weak self] in
            guard let self, self.hintGeneration == mine else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self.gridHint.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { if self.hintGeneration == mine { self.gridHint.isHidden = true } }
            }
        }
    }

    private func hideGridHint() {
        hintGeneration += 1
        gridHint.isHidden = true
        gridHint.alphaValue = 0
    }

    private static let gridHintDuration: TimeInterval = 3

    var isGridHintVisible: Bool { !gridHint.isHidden && gridHint.alphaValue > 0 }

    private func updateWaiting(_ session: TerminalSession, engine: SwiftTermEngine) {
        let waiting = session.isCommandRunning && engine.cursorColumn > 0
        guard waiting != waitingForAnswer else { return }
        waitingForAnswer = waiting
        syncEditor(session)
    }

    private func syncEditor(_ session: TerminalSession) {
        let colors = colors
        editor.apply(font: font, colors: colors)
        editor.forwardsKeys = session.isCommandRunning
        if !session.isCommandRunning { waitingForAnswer = false }
        switch session.phase {
        case .ended, .failed: editor.placeholder = "Sessão encerrada"
        case .idle, .running:
            editor.placeholder = session.isCommandRunning
                ? (waitingForAnswer ? "Digite a resposta para o programa" : "Comando em execução: as teclas vão para o programa")
                : "Digite um comando (⇧↩ para nova linha)"
        }
        editor.isEditable = session.phase == .running
    }

    private func syncChips(_ session: TerminalSession) {
        let directory = session.directory
        let directoryChanged = directory != chipsDirectory
        let finishedID = ContextChips.lastFinishedID(session.blocks.blocks)
        let commandFinished = finishedID != chipsFinishedID
        chipsFinishedID = finishedID
        if directoryChanged { gitStatus = nil }
        if directoryChanged || commandFinished { reloadGit(directory: directory) }
        if directoryChanged || renderedChipsColors != colors {
            chipsDirectory = directory
            renderedChipsColors = colors
            completionMenu.needsDisplay = true
            chipsView.update(directory: directory, git: gitStatus)
        }
    }

    private func reloadGit(directory: String) {
        chipsGeneration += 1
        let generation = chipsGeneration
        Task { [weak self] in
            let status = await GitStatusReader.read(directory: directory)
            guard let self, generation == self.chipsGeneration, status != self.gitStatus else { return }
            self.gitStatus = status
            self.chipsView.update(directory: directory, git: status)
        }
    }

    // MARK: Completion

    private func resolveShellPath() {
        guard shellPath == nil, !resolvingShellPath,
              lastShellPathAttempt.map({ Date().timeIntervalSince($0) >= LoginPATHCache.retryInterval }) ?? true else { return }
        resolvingShellPath = true
        lastShellPathAttempt = Date()
        let fallback = Self.fallbackPath
        Task.detached(priority: .utility) { [weak self] in
            CompletionContext.warmExecutables(path: fallback)
            let found = ClaudeLocator.cachedLoginShellPATH
            if let found { CompletionContext.warmExecutables(path: found) }
            await MainActor.run {
                self?.shellPath = found
                self?.resolvingShellPath = false
                self?.editor.highlight()
            }
        }
    }

    private static var fallbackPath: String {
        LoginPATHCache.fallback(base: ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory())
    }

    private func completions(line: String, cursor: Int) -> [Completion] {
        guard let session else { return [] }
        resolveShellPath()
        let path = shellPath ?? Self.fallbackPath
        let context = CompletionContext.live(cwd: session.directory, home: session.home ?? NSHomeDirectory(), path: { path })
        return CompletionEngine.complete(line: line, cursor: cursor, context: context)
    }

    private func syncCompletionMenu() {
        if let query = editor.searchDisplayQuery {
            let rows = editor.searchResults.map {
                Completion(insertText: $0, display: $0.replacingOccurrences(of: "\n", with: " ⏎ "), kind: .builtin, replaceRange: 0..<0)
            }
            let items = rows.isEmpty ? [Completion(insertText: "", display: "Nenhum resultado", kind: .builtin, replaceRange: 0..<0)] : rows
            completionMenu.isHidden = false
            completionMenu.update(
                items: items, selected: editor.searchSelection, font: font, header: "⌃R  \(query)", symbol: "clock.arrow.circlepath")
            needsLayout = true
            return
        }
        let items = editor.completions
        completionMenu.isHidden = items.isEmpty
        if !items.isEmpty { completionMenu.update(items: items, selected: editor.completionSelection, font: font) }
        needsLayout = true
    }

    // MARK: History and keys

    private func seedHistory(_ session: TerminalSession) {
        guard let file = session.historyFile, file != unreadableHistoryFile, CommandHistory.shared.claimSeed() else { return }
        let metafied = session.shell.name == "zsh"
        Task.detached(priority: .utility) { [weak self] in
            if let loaded = HistoryParser.load(path: file, metafied: metafied) {
                CommandHistory.shared.seed(with: loaded)
            } else {
                CommandHistory.shared.releaseSeed()
                await MainActor.run { self?.unreadableHistoryFile = file }
            }
        }
    }

    func clearBlocks() {
        session?.replaceBlocks([])
    }

    private var programNames = Set<String>()
    private var programCount = -1

    private func programSet() -> Set<String> {
        let path = shellPath ?? Self.fallbackPath
        let found = CompletionContext.live(cwd: "", home: NSHomeDirectory(), path: { path }).executables()
        if found.count != programCount {
            programCount = found.count
            programNames = Set(found).union(CompletionEngine.builtins)
        }
        return programNames
    }

    private func isProgram(_ word: String) -> Bool {
        let names = programSet()
        return programCount == 0 || names.contains(word)
    }

    private func isProgramPrefix(_ word: String) -> Bool {
        programSet().contains { $0.hasPrefix(word) }
    }

    // MARK: Layout

    static let gridInset: CGFloat = 4

    override func layout() {
        super.layout()
        guard let engine else { return }
        let grid = engine.view
        let gridFrame = bounds.insetBy(dx: Self.gridInset, dy: Self.gridInset)
        if grid.frame != gridFrame { grid.frame = gridFrame }
        layoutGridHint()
        guard !showsGrid else { return }
        needsDisplay = true
        let x = Self.inputInsetLeading
        let width = max(1, bounds.width - Self.inputInsetLeading - Self.inputInsetTrailing)
        let chipsHeight = ContextChipsView.height
        let editorHeight = min(editor.fittingHeight(forWidth: width), editor.maxHeight, max(24, bounds.height * Self.maxEditorFraction))
        let spacing: CGFloat = 4
        let area = Self.inputInsetVertical * 2 + chipsHeight + spacing + editorHeight
        list.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - area))
        var y = bounds.height - area + Self.inputInsetVertical
        chipsView.frame = NSRect(x: x, y: y, width: width, height: chipsHeight)
        y += chipsHeight + spacing
        editorScroll.frame = NSRect(x: x, y: y, width: width, height: editorHeight)
        editor.frame.size.width = width
        editor.setFrameSize(NSSize(width: width, height: max(editorHeight, editor.fittingHeight(forWidth: width))))
        layoutCompletionMenu(above: chipsView.frame.minY)
    }

    private func layoutGridHint() {
        guard !gridHint.isHidden else { return }
        let size = gridHint.fittingSize
        gridHint.frame = NSRect(x: bounds.width - size.width - 20, y: 10, width: size.width + 12, height: size.height + 4)
        gridHint.alignment = .center
    }

    private func layoutCompletionMenu(above bottom: CGFloat) {
        guard !completionMenu.isHidden else { return }
        let searching = editor.isSearchingHistory
        let available = Int((bottom - 4 - CompletionMenuView.height(rows: 0, header: searching)) / 24)
        let count = searching ? max(1, editor.searchResults.count) : editor.completions.count
        let rows = max(1, min(CompletionMenuView.visibleRows(for: count), available))
        let height = CompletionMenuView.height(rows: rows, header: searching)
        let width = completionMenu.fittingWidth(limit: max(160, bounds.width - 2 * Self.inputInsetLeading))
        let anchor = (searching ? nil : editor.completionAnchor()).map { editor.convert($0, to: self).x } ?? Self.inputInsetLeading
        let x = max(Self.inputInsetLeading / 2, min(anchor, bounds.width - width - Self.inputInsetTrailing))
        completionMenu.frame = NSRect(x: x, y: max(0, bottom - 4 - height), width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !showsGrid, session != nil else { return }
        NSColor(Theme.stroke).setFill()
        NSRect(x: 0, y: list.frame.maxY, width: bounds.width, height: 1).fill()
    }
}
