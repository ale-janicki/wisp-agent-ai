import AppKit
import Foundation
import Observation
import os
import WispCore

struct BrainConflict: Equatable {
    enum Kind { case changed, deleted }

    var kind: Kind
    var disk: String
    var mine: String
    var merged: String
    var hasMarkers: Bool
}

struct BrainOpenNote: Identifiable, Equatable {
    let id = UUID()
    var path: String
    var kind: BrainFileKind
    var text = ""
    var base = ""
    var editing = false
    var render = BrainRenderModel.empty
    var history = BrainHistory()
    var conflict: BrainConflict?
    var loading = true
    var failure: String?
    var revision = 0
    var jumpLine: Int?
    var jumpSeq = 0
    var readOnly: String?
    var gen = 0
    var allowMarkers = false

    var dirty: Bool { text != base }
    var title: String { BrainTree.displayName(path, isFolder: false) }

    mutating func reopen(_ newPath: String) {
        path = newPath
        kind = BrainFileKind.of(newPath)
        text = ""
        base = ""
        editing = false
        render = .empty
        conflict = nil
        loading = true
        failure = nil
        revision += 1
        jumpLine = nil
        jumpSeq += 1
        readOnly = nil
        allowMarkers = false
        gen += 1
    }

    var holdsMarkers: Bool { !allowMarkers && BrainMerge.hasMarkers(text) }
}

enum BrainPrompt: Identifiable {
    case newNote(folder: String)
    case newFolder(folder: String)
    case rename(path: String, isFolder: Bool)
    case missing(name: String, source: String)
    case delete(path: String, isFolder: Bool)
    case move(BrainMovePlan)

    var id: String {
        switch self {
        case .newNote(let folder): "note|\(folder)"
        case .newFolder(let folder): "folder|\(folder)"
        case .rename(let path, _): "rename|\(path)"
        case .missing(let name, let source): "missing|\(name)|\(source)"
        case .delete(let path, _): "delete|\(path)"
        case .move(let plan): "move|\(plan.from)|\(plan.to)"
        }
    }
}

enum BrainSidePanel: String, CaseIterable {
    case backlinks, outgoing, outline, tags

    var title: String {
        switch self {
        case .backlinks: "Backlinks"
        case .outgoing: "Links"
        case .outline: "Tópicos"
        case .tags: "Tags"
        }
    }
}

@MainActor @Observable
final class BrainModel {
    static let shared = BrainModel()

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var root: String?
    private(set) var catalog = BrainCatalog(notes: [])
    private(set) var entries: [BrainFileEntry] = []
    private(set) var rows: [BrainTreeRow] = []
    private(set) var switcherEntries: [BrainSwitcherEntry] = []
    private(set) var fileResolver = BrainFileResolver(paths: [])
    private(set) var tabs: [BrainOpenNote] = []
    private(set) var activeID: UUID?
    private(set) var backlinks: [BrainBacklink] = []
    private(set) var tagCounts: [String: Int] = [:]
    private(set) var daily = BrainDailyConfig()
    private(set) var templates: [String] = []
    private(set) var bookmarks = BrainBookmarks()
    private(set) var searchHits: [BrainSearchHit] = []
    private(set) var searching = false
    private(set) var scanMillis = 0
    private(set) var scanTick = 0
    var expanded = Set<String>()
    var prompt: BrainPrompt?
    var message: String?
    var showsSwitcher = false
    var showsGraph = true
    var browsing = false
    private(set) var searchFocusTick = 0
    var showsTree = true
    var sidePanel: BrainSidePanel?
    var searchError: String?
    var searchQuery = ""
    var pendingInsert: String?

    @ObservationIgnored private var treeIndex = BrainTree.Index(entries: [])
    @ObservationIgnored private var watcher: BrainWatcher?
    @ObservationIgnored private var recoveryLedger = BrainRecoveryLedger()
    @ObservationIgnored private lazy var quitRegistration = BrainQuitRegistration { [weak self] in self?.flushForQuit() }
    @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var backlinkTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "brain-app")

    static let autosaveDelay: Duration = .milliseconds(800)

    var active: BrainOpenNote? { tabs.first { $0.id == activeID } }
    var files: BrainFiles? { root.map { BrainFiles(root: $0) } }

    var recoveryFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wisp/brain-recuperado", isDirectory: true)
    }

    private var bookmarksURL: URL {
        let configured = WispConfigFile().string("wisp_dir") ?? "~/Wisp"
        return URL(fileURLWithPath: expandTilde(configured), isDirectory: true).appendingPathComponent("brain-bookmarks.json")
    }


    func load(root rawRoot: String) {
        let resolved = MemorySearch.resolvedRoot(rawRoot)
        if root == resolved, phase != .idle { return }
        stop()
        root = resolved
        phase = .loading
        tabs = []
        activeID = nil
        bookmarks = BrainBookmarks.load(from: bookmarksURL, root: resolved)
        expanded = Set(UserDefaults.standard.stringArray(forKey: "brain.expanded.\(resolved)") ?? [])
        Task.detached(priority: .utility) { BrainFiles.removeStaleTemps(root: resolved) }
        scan(restoring: true)
        watcher = BrainWatcher(root: resolved) { [weak self] in
            Task { @MainActor in self?.scheduleRescan() }
        }
    }

    func stop() {
        flush()
        watcher?.stop()
        watcher = nil
        rescanTask?.cancel()
        quitRegistration.update(hasOpenNotes: false)
    }

    private func scan(restoring: Bool = false) {
        guard let root else { return }
        scanGeneration += 1
        let generation = scanGeneration
        let previous = catalog
        Task { [weak self] in
            let started = Date()
            let scan = await Task.detached(priority: .userInitiated) { BrainScanner.scan(root: root, previous: previous) }.value
            guard let self, self.scanGeneration == generation else { return }
            guard let scan else {
                self.phase = .failed("a pasta \(root) não está acessível")
                return
            }
            self.apply(scan)
            self.scanMillis = Int(Date().timeIntervalSince(started) * 1000)
            self.scanTick += 1
            self.phase = .ready
            if restoring { self.restoreTabs() }
            await self.checkOpenNotes()
            self.refreshSide()
        }
    }

    private func apply(_ scan: BrainScan) {
        catalog = scan.catalog
        entries = scan.entries
        treeIndex = BrainTree.Index(entries: scan.entries)
        rows = treeIndex.rows(expanded: expanded)
        switcherEntries = BrainSwitcher.entries(from: scan.catalog)
        fileResolver = BrainFileResolver(paths: scan.entries.filter { !$0.isFolder }.map(\.path))
        tagCounts = scan.catalog.tagCounts()
        let paths = scan.catalog.notes.keys.sorted()
        if let root {
            daily = BrainDailyConfig.load(root: root, notes: paths)
            let folder = BrainDailyConfig.templatesFolder(root: root, notes: paths)
            templates = folder.map { prefix in paths.filter { BrainText.parent(of: $0) == prefix } } ?? []
        }
    }

    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    func refreshTree() {
        rows = treeIndex.rows(expanded: expanded)
        if let root { UserDefaults.standard.set(Array(expanded).sorted(), forKey: "brain.expanded.\(root)") }
    }

    func toggleFolder(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        refreshTree()
    }

    func reveal(_ path: String) {
        let parents = BrainTree.ancestors(of: path)
        guard !parents.allSatisfy(expanded.contains) else { return }
        expanded.formUnion(parents)
        refreshTree()
    }


    func open(_ path: String, line: Int? = nil, heading: String? = nil, newTab: Bool = false) {
        guard let files else { return }
        message = nil
        browsing = false
        let kind = BrainFileKind.of(path)
        if kind == .other, let url = try? files.url(path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        flushActive()
        if newTab || active == nil {
            if let existing = tabs.first(where: { $0.path == path }) {
                activeID = existing.id
                jump(to: line, heading: heading)
            } else {
                var tab = BrainOpenNote(path: path, kind: kind)
                tab.history.visit(path)
                tabs.append(tab)
                activeID = tab.id
                load(tab: tab.id, line: line, heading: heading)
            }
        } else if let current = active, let index = tabs.firstIndex(where: { $0.id == current.id }) {
            if current.path == path {
                jump(to: line, heading: heading)
            } else {
                tabs[index].history.visit(path)
                tabs[index].reopen(path)
                load(tab: current.id, line: line, heading: heading)
            }
        }
        reveal(path)
        persistTabs()
        refreshSide()
    }

    func activate(_ id: UUID) {
        guard id != activeID else { return }
        flushActive()
        activeID = id
        persistTabs()
        refreshSide()
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        save(id)
        if let tab = tabs.first(where: { $0.id == id }), tab.dirty, tab.readOnly == nil {
            guard BrainRecovery.save(tab.text, named: tab.path, in: recoveryFolder) != nil else {
                message = "Não consegui guardar uma cópia do texto não salvo; a aba continua aberta."
                return
            }
            message = "Texto não salvo guardado em Application Support/Wisp/brain-recuperado."
        }
        tabs.remove(at: index)
        if activeID == id { activeID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id }
        persistTabs()
        refreshSide()
    }

    func goBack() { step { $0.back() } }
    func goForward() { step { $0.forward() } }

    private func step(_ move: (inout BrainHistory) -> String?) {
        guard let current = active, let index = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        flushActive()
        var history = current.history
        guard let path = move(&history) else { return }
        tabs[index].history = history
        tabs[index].reopen(path)
        load(tab: current.id, line: nil, heading: nil)
        reveal(path)
        persistTabs()
        refreshSide()
    }

    private func update(_ id: UUID?, _ change: (inout BrainOpenNote) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }

    func jump(toLine line: Int) {
        update(activeID) {
            $0.jumpLine = line
            $0.jumpSeq += 1
        }
    }

    private func jump(to line: Int?, heading: String?) {
        guard let active else { return }
        let target = line ?? heading.flatMap { active.render.headingLine(matching: $0) }
        update(activeID) {
            $0.jumpLine = target
            $0.jumpSeq += 1
        }
    }

    private func load(tab id: UUID, line: Int?, heading: String?) {
        guard let tab = tabs.first(where: { $0.id == id }), let files else { return }
        let path = tab.path
        guard tab.kind == .note else {
            update(id) { $0.loading = false }
            return
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try files.inspect(path) } }.value
            guard let self else { return }
            switch result {
            case .success(let loaded):
                let text = loaded.text
                let model = await Task.detached(priority: .userInitiated) { BrainMarkdown.parse(text) }.value
                self.update(id) {
                    guard $0.path == path else { return }
                    $0.text = text
                    $0.base = text
                    $0.render = model
                    $0.loading = false
                    $0.failure = nil
                    $0.readOnly = loaded.readOnlyReason
                    $0.gen += 1
                    $0.revision += 1
                    $0.jumpLine = line ?? heading.flatMap { model.headingLine(matching: $0) }
                    $0.jumpSeq += 1
                }
                self.refreshSide()
            case .failure(let error):
                self.update(id) {
                    $0.loading = false
                    $0.failure = error.localizedDescription
                }
            }
        }
    }

    private func persistTabs() {
        guard let root else { return }
        UserDefaults.standard.set(tabs.map(\.path), forKey: "brain.tabs.\(root)")
        UserDefaults.standard.set(active?.path, forKey: "brain.active.\(root)")
        updateQuitRegistration()
    }

    private func updateQuitRegistration() {
        quitRegistration.update(hasOpenNotes: tabs.contains { $0.kind == .note })
    }

    private func restoreTabs() {
        guard let root else { return }
        let saved = UserDefaults.standard.stringArray(forKey: "brain.tabs.\(root)") ?? []
        let activePath = UserDefaults.standard.string(forKey: "brain.active.\(root)")
        for path in saved where files?.exists(path) == true {
            var tab = BrainOpenNote(path: path, kind: BrainFileKind.of(path))
            tab.history.visit(path)
            tabs.append(tab)
            load(tab: tab.id, line: nil, heading: nil)
        }
        activeID = tabs.first { $0.path == activePath }?.id ?? tabs.first?.id
        if let path = active?.path { reveal(path) }
        updateQuitRegistration()
    }

    func resolve(_ link: BrainWikiLink, from source: String) -> String? {
        if link.name.isEmpty { return source }
        return catalog.resolve(link.name, from: source)
    }

    func follow(_ link: BrainWikiLink, from source: String, newTab: Bool = false) {
        if let path = resolve(link, from: source) {
            open(path, heading: link.heading.isEmpty ? nil : link.heading, newTab: newTab)
        } else {
            prompt = .missing(name: link.name, source: source)
        }
    }

    /// A link clicked inside a drawing or canvas: `name` or `name#heading`, resolved from the drawing's own path.
    func openFromDrawing(_ link: String, drawingPath: String) {
        let parts = link.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        follow(BrainWikiLink(name: String(parts[0]), heading: parts.count > 1 ? String(parts[1]) : ""), from: drawingPath)
    }

    func resolveFile(_ name: String, from source: String) -> String? {
        fileResolver.resolve(name, from: source)
    }

    func url(for path: String) -> URL? { try? files?.url(path) }


    func edit(_ id: UUID, text: String) {
        guard let tab = tabs.first(where: { $0.id == id }), tab.readOnly == nil, tab.conflict == nil else { return }
        update(id) {
            $0.text = text
            $0.gen += 1
            if !BrainMerge.hasMarkers(text) { $0.allowMarkers = false }
        }
        scheduleSave(id)
    }

    func toggleEditing() {
        guard let current = active, current.kind == .note, current.readOnly == nil else {
            if active?.readOnly != nil { message = active?.readOnly }
            return
        }
        if current.editing {
            save(current.id)
            reparse(current.id)
        }
        update(current.id) { $0.editing.toggle() }
    }

    private func reparse(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let text = tab.text
        Task { [weak self] in
            let model = await Task.detached(priority: .userInitiated) { BrainMarkdown.parse(text) }.value
            self?.update(id) { if $0.text == text { $0.render = model } }
            self?.refreshSide()
        }
    }

    private func scheduleSave(_ id: UUID) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveTasks[id] = nil
            self?.save(id)
        }
    }

    func flushActive() {
        if let id = activeID { save(id) }
    }

    func flush() {
        for task in saveTasks.values { task.cancel() }
        saveTasks = [:]
        for tab in tabs { save(tab.id) }
    }

    @discardableResult
    func flushForQuit() -> [String] {
        flush()
        var lost: [String] = []
        for tab in tabs where tab.kind == .note && tab.dirty && tab.readOnly == nil {
            guard recoveryLedger.shouldCopy(tab.path, text: tab.text) else { continue }
            if BrainRecovery.save(tab.text, named: tab.path, in: recoveryFolder) == nil {
                recoveryLedger.forget(tab.path)
                lost.append(tab.path)
                log.error("quit: could not keep a recovery copy of \(tab.path, privacy: .public)")
            }
        }
        return lost
    }

    @discardableResult
    func save(_ id: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), tab.kind == .note, tab.dirty, tab.conflict == nil, !tab.loading, tab.readOnly == nil, let files else { return true }
        if tab.holdsMarkers { return false }
        guard let disk = try? files.read(tab.path), disk == tab.base else {
            Task { [weak self] in await self?.checkOpenNotes() }
            return false
        }
        do {
            try files.write(tab.text, to: tab.path)
            update(id) {
                $0.base = tab.text
                $0.gen += 1
            }
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func toggleTask(line: Int, raw: String) {
        guard let tab = active, tab.readOnly == nil, tab.conflict == nil else { return }
        guard let next = BrainTasks.toggle(in: tab.text, line: line, expected: raw) else {
            message = "A nota mudou; atualizei a tela e não marquei nada."
            reparse(tab.id)
            return
        }
        update(tab.id) {
            $0.text = next
            $0.render = BrainMarkdown.parse(next)
        }
        save(tab.id)
    }

    func setProperty(_ key: String, to value: BrainProperty.Value) {
        guard let tab = active, tab.readOnly == nil, tab.conflict == nil else { return }
        var document = BrainDocument(tab.text)
        document.set(key, to: value)
        replaceText(tab.id, with: document.text)
    }

    func removeProperty(_ key: String) {
        guard let tab = active, tab.readOnly == nil, tab.conflict == nil else { return }
        var document = BrainDocument(tab.text)
        document.remove(key)
        replaceText(tab.id, with: document.text)
    }

    private func replaceText(_ id: UUID, with text: String) {
        update(id) {
            $0.gen += 1
            $0.text = text
            $0.revision += 1
        }
        reparse(id)
        scheduleSave(id)
    }


    private func readDisk(_ files: BrainFiles, _ path: String) async -> BrainFiles.Presence {
        var state = await Task.detached(priority: .utility) { files.presence(path) }.value
        var attempts = 0
        while state == .absent, attempts < 2 {
            try? await Task.sleep(for: .milliseconds(300))
            state = await Task.detached(priority: .utility) { files.presence(path) }.value
            attempts += 1
        }
        return state
    }

    private func checkOpenNotes() async {
        guard let files else { return }
        for tab in tabs where tab.kind == .note && !tab.loading && tab.readOnly == nil {
            let path = tab.path
            let snapshot = (text: tab.text, base: tab.base, gen: tab.gen)
            let state = await readDisk(files, path)
            guard let current = tabs.first(where: { $0.id == tab.id }), current.path == path, current.conflict == nil,
                  current.gen == snapshot.gen, current.text == snapshot.text, current.base == snapshot.base else { continue }
            let disk: String
            switch state {
            case .unreadable:
                message = "Não consegui ler \(path) agora; mantive o que está na tela."
                continue
            case .absent:
                if current.dirty {
                    if BrainRecovery.save(current.text, named: path, in: recoveryFolder) == nil {
                        message = "A nota \(path) sumiu do disco e não consegui guardar uma cópia; o texto continua na tela."
                    }
                    update(tab.id) { $0.conflict = BrainConflict(kind: .deleted, disk: "", mine: $0.text, merged: $0.text, hasMarkers: false) }
                } else {
                    close(tab.id)
                    message = "A nota \(path) foi removida ou movida fora do Wisp."
                }
                continue
            case .text(let text):
                disk = text
            }
            switch BrainMerge.merge(base: current.base, mine: current.text, theirs: disk) {
            case .unchanged:
                if current.base != disk {
                    update(tab.id) {
                        $0.base = disk
                        $0.gen += 1
                    }
                }
            case .reload(let text):
                update(tab.id) {
                    $0.text = text
                    $0.base = text
                    $0.gen += 1
                    $0.revision += 1
                }
                reparse(tab.id)
            case .merged(let text):
                update(tab.id) { $0.conflict = BrainConflict(kind: .changed, disk: disk, mine: $0.text, merged: text, hasMarkers: false) }
            case .conflict(let text):
                update(tab.id) { $0.conflict = BrainConflict(kind: .changed, disk: disk, mine: $0.text, merged: text, hasMarkers: true) }
            }
        }
    }

    func resolveConflict(_ choice: ConflictChoice) {
        guard let tab = active, let conflict = tab.conflict else { return }
        switch choice {
        case .keepMine:
            if conflict.kind == .changed {
                guard keepCopy(conflict.disk, of: tab.path) else { return }
                update(tab.id) {
                    $0.base = conflict.disk
                    $0.conflict = nil
                    $0.gen += 1
                }
                save(tab.id)
            } else {
                do {
                    try files?.createNote(tab.path, text: tab.text)
                    update(tab.id) {
                        $0.base = tab.text
                        $0.conflict = nil
                        $0.gen += 1
                    }
                } catch {
                    message = error.localizedDescription
                }
            }
        case .useDisk:
            guard keepCopy(tab.text, of: tab.path) else { return }
            update(tab.id) {
                $0.text = conflict.disk
                $0.base = conflict.disk
                $0.conflict = nil
                $0.gen += 1
                $0.revision += 1
            }
            reparse(tab.id)
        case .merge:
            if tab.text != conflict.mine, !keepCopy(tab.text, of: tab.path) { return }
            let merged: String
            switch BrainMerge.merge(base: tab.base, mine: tab.text, theirs: conflict.disk) {
            case .merged(let text), .conflict(let text), .reload(let text): merged = text
            case .unchanged: merged = tab.text
            }
            update(tab.id) {
                $0.text = merged
                $0.base = conflict.disk
                $0.conflict = nil
                $0.allowMarkers = false
                $0.gen += 1
                $0.revision += 1
            }
            reparse(tab.id)
            scheduleSave(tab.id)
        }
    }

    private func keepCopy(_ text: String, of path: String) -> Bool {
        guard BrainRecovery.save(text, named: path, in: recoveryFolder) != nil else {
            message = "Não consegui guardar uma cópia do texto que seria descartado; nada foi alterado."
            return false
        }
        return true
    }

    func saveDespiteMarkers() {
        guard let tab = active else { return }
        update(tab.id) { $0.allowMarkers = true }
        save(tab.id)
    }

    enum ConflictChoice { case keepMine, useDisk, merge }


    func refreshSide() {
        backlinkTask?.cancel()
        guard let tab = active, tab.kind == .note, let files else {
            backlinks = []
            return
        }
        let path = tab.path
        let catalog = catalog
        backlinkTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { BrainBacklinks.find(for: path, catalog: catalog, files: files) }.value
            guard !Task.isCancelled else { return }
            self?.backlinks = found
        }
    }

    func outgoing(of tab: BrainOpenNote) -> [BrainResolvedLink] {
        BrainBacklinks.outgoing(text: tab.text, source: tab.path, catalog: catalog)
    }


    func createNote(named name: String, in folder: String) {
        guard let files else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        let file = clean.lowercased().hasSuffix(".md") ? clean : clean + ".md"
        let path = BrainTree.uniquePath(BrainText.join(folder, file), existing: Set(entries.map(\.path)))
        do {
            try files.createNote(path, text: "")
            finishCreate(path)
        } catch {
            message = error.localizedDescription
        }
    }

    func createDrawing(_ kind: BrainNewDrawing.Kind, in folder: String) {
        guard let files else { return }
        do {
            let path = try BrainNewDrawing.create(kind, in: folder, files: files, knownPaths: Set(entries.map(\.path)))
            entries.append(BrainFileEntry(path: path, isFolder: false))
            treeIndex = BrainTree.Index(entries: entries)
            if !folder.isEmpty { expanded.insert(folder) }
            open(path, newTab: true)
            scan()
        } catch {
            message = error.localizedDescription
        }
    }

    func createFolder(named name: String, in folder: String) {
        guard let files else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        do {
            try files.createFolder(BrainText.join(folder, clean))
            expanded.insert(folder)
            scan()
        } catch {
            message = error.localizedDescription
        }
    }

    func createMissing(name: String, from source: String) {
        let folder = BrainText.parent(of: source)
        createNote(named: name, in: folder)
    }

    private func finishCreate(_ path: String) {
        let kind = BrainFileKind.of(path)
        entries.append(BrainFileEntry(path: path, isFolder: false))
        treeIndex = BrainTree.Index(entries: entries)
        open(path)
        if kind == .note { update(activeID) { $0.editing = true } }
        scan()
    }

    func openDaily() {
        guard let files else { return }
        let path = daily.path(for: Date())
        if !files.exists(path) {
            var text = ""
            if let template = daily.template, let source = try? files.read(template) {
                text = BrainTemplate.render(source, title: BrainText.stem(of: path), date: Date())
            }
            do { try files.createNote(path, text: text) } catch {
                message = error.localizedDescription
                return
            }
            entries.append(BrainFileEntry(path: path, isFolder: false))
            treeIndex = BrainTree.Index(entries: entries)
            scan()
        }
        open(path)
    }

    func insertTemplate(_ path: String) {
        guard let files, let tab = active, tab.kind == .note, tab.readOnly == nil, tab.conflict == nil, let source = try? files.read(path) else { return }
        let rendered = BrainTemplate.render(source, title: BrainText.stem(of: tab.path), date: Date())
        if tab.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            replaceText(tab.id, with: rendered)
        } else {
            update(tab.id) { $0.editing = true }
            pendingInsert = rendered
        }
    }

    func requestRename(_ path: String) {
        let isFolder = entries.first { $0.path == path }?.isFolder ?? false
        prompt = .rename(path: path, isFolder: isFolder)
    }

    func planMove(from: String, to: String) {
        guard let root, from != to else { return }
        flush()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<BrainMovePlan, Error> in
                guard let fresh = BrainScanner.scan(root: root) else { return .failure(BrainFilesError.missing(root)) }
                return Result { try BrainRefactor.plan(root: root, scan: fresh, from: from, to: to) }
            }.value
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.prompt = nil
                self.message = error.localizedDescription
            case .success(let plan) where plan.linkCount == 0 && plan.isComplete:
                self.apply(plan)
            case .success(let plan):
                self.prompt = .move(plan)
            }
        }
    }

    func apply(_ plan: BrainMovePlan) {
        guard let root else { return }
        prompt = nil
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try BrainRefactor.applyFresh(plan, root: root) } }.value
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.message = error.localizedDescription
            case .success:
                self.afterMove(plan)
            }
        }
    }

    private func afterMove(_ plan: BrainMovePlan) {
        func relocated(_ path: String) -> String {
            if path == plan.from { return plan.to }
            if path.hasPrefix(plan.from + "/") { return plan.to + path.dropFirst(plan.from.count) }
            return path
        }
        for index in tabs.indices {
            let old = tabs[index].path
            tabs[index].path = relocated(old)
            tabs[index].history.rename(plan.from, to: plan.to)
        }
        bookmarks.rename(plan.from, to: plan.to)
        saveBookmarks()
        expanded = Set(expanded.map(relocated))
        if plan.isFolder { expanded.insert(plan.to) }
        persistTabs()
        message = nil
        scan()
    }

    func trash(_ path: String) {
        guard let files else { return }
        prompt = nil
        do {
            try files.trash(path)
        } catch {
            message = error.localizedDescription
            return
        }
        for tab in tabs where tab.path == path || tab.path.hasPrefix(path + "/") { tabs.removeAll { $0.id == tab.id } }
        if !tabs.contains(where: { $0.id == activeID }) { activeID = tabs.last?.id }
        for index in tabs.indices { tabs[index].history.forget(path) }
        bookmarks.forget(path)
        saveBookmarks()
        persistTabs()
        scan()
    }

    func moveByDrop(_ source: String, into folder: String) {
        let name = (source as NSString).lastPathComponent
        let target = BrainText.join(folder, name)
        guard target != source, folder != BrainText.parent(of: source), !(folder + "/").hasPrefix(source + "/") else { return }
        planMove(from: source, to: target)
    }


    func toggleBookmark(_ path: String) {
        bookmarks.toggle(path)
        saveBookmarks()
    }

    private func saveBookmarks() {
        guard let root else { return }
        do { try bookmarks.save(to: bookmarksURL, root: root) } catch { message = "Não consegui salvar os favoritos: \(error.localizedDescription)" }
    }


    func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let root else {
            searchHits = []
            searching = false
            searchError = nil
            return
        }
        searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let layout = RuntimeLayout(bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
            let wisp = layout.wisp
            let environment = BrainColher.environment(wisp: wisp, base: ProcessInfo.processInfo.environment, loginPATH: ClaudeLocator.cachedLoginShellPATH)
            let result = await Task.detached(priority: .userInitiated) {
                BrainSearchClient.run(wisp: wisp, environment: environment, root: root, query: trimmed)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.searching = false
            switch result {
            case .success(let hits):
                self.searchHits = hits
                self.searchError = nil
            case .failure(let error):
                self.searchHits = []
                self.searchError = error.localizedDescription
            }
        }
    }

    func focusSearch() {
        browsing = true
        searchFocusTick += 1
    }

    func searchTag(_ name: String) {
        searchQuery = "#" + name
        showsGraph = false
        focusSearch()
    }

    func closeOverlays() {
        prompt = nil
        showsSwitcher = false
    }

    func dismissOverlay() -> Bool {
        if prompt != nil { prompt = nil; return true }
        if showsSwitcher { showsSwitcher = false; return true }
        return false
    }

    func switcherResults(_ query: String) -> [BrainSwitcherResult] {
        BrainSwitcher.rank(query, in: switcherEntries, limit: 40)
    }

    func switcherResultsForCompletion(_ query: String) -> [BrainSwitcherResult] {
        BrainSwitcher.rank(query, in: switcherEntries, limit: 12)
    }
}
