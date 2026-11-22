import AppKit
import Observation
import os
import SwiftUI
import UniformTypeIdentifiers
import WispCore

@MainActor @Observable
final class BrainDrawingModel {
    enum Status: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let url: URL
    let host = DrawingWebHost()
    private(set) var status = Status.loading
    private(set) var saveNote = ""
    private(set) var externalChangePending = false
    private(set) var readOnlyNotice: String?
    var editing = false {
        didSet {
            guard editing != oldValue else { return }
            if editing, readOnlyNotice != nil {
                editing = false
                return
            }
            perform(session.setEditing(editing, pageReady: pageReady))
        }
    }

    @ObservationIgnored private let vaultRoot: URL?
    @ObservationIgnored private let openNote: (String) -> Void
    @ObservationIgnored private let onNotice: (String) -> Void
    @ObservationIgnored private var session = DrawingEditSession()
    @ObservationIgnored private var editedThisSession = false
    @ObservationIgnored private let closer = DrawingClosingTracker()
    private var closing: Bool { closer.isClosing }
    @ObservationIgnored private var quitToken: UUID?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var file: ExcalidrawFile?
    @ObservationIgnored private var state = DrawingFileState()
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var dark = true
    @ObservationIgnored private var pageReady = false
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "drawings")

    private static let autosaveDelay: Duration = .milliseconds(600)
    private static let pollInterval: Duration = .seconds(1.5)

    init(url: URL, vaultRoot: URL?, dark: Bool, openNote: @escaping (String) -> Void, onNotice: @escaping (String) -> Void) {
        self.url = url
        self.vaultRoot = vaultRoot
        self.dark = dark
        self.openNote = openNote
        self.onNotice = onNotice
        host.onEvent = { [weak self] event in self?.handle(event) }
    }

    func start() {
        guard host.resourcesPresent else {
            status = .failed("O Excalidraw não está dentro do app. Rode scripts/build-excalidraw.sh e gere o app de novo.")
            return
        }
        host.loadPage()
        quitToken = QuitFlush.shared.register { [self] in await flushForQuit() }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                self?.checkDisk()
            }
        }
    }

    func stop() {
        guard !closing else { return }
        closer.begin()
        autosave?.cancel()
        watcher?.cancel()
        if session.pageDirty, pageReady {
            host.onEvent = { event in self.handle(event) }
            host.send(.requestSave)
            Task {
                await DrawingCloseWait.until(timeout: .seconds(3)) { !self.session.pageDirty || self.externalChangePending }
                self.finishClosing()
            }
        } else {
            finishClosing()
        }
    }

    func flushForQuit() async {
        if closing {
            await closer.waitUntilFinished()
            return
        }
        if session.pageDirty, pageReady {
            host.send(.requestSave)
            await DrawingCloseWait.until(timeout: .seconds(2)) { !self.session.pageDirty || self.externalChangePending }
        }
        if session.pendingScene != nil {
            writePending()
            if externalChangePending { saveRecoveryCopy() }
        }
        warnIfEditsWereLost()
    }

    private func warnIfEditsWereLost() {
        guard session.pageDirty, session.pendingScene == nil, !externalChangePending else { return }
        log.error("drawing page did not answer the last save request for \(self.url.lastPathComponent, privacy: .public)")
        onNotice("Não consegui salvar as últimas edições de \(url.lastPathComponent): a página não respondeu a tempo.")
    }

    private func finishClosing() {
        warnIfEditsWereLost()
        var conflicted = externalChangePending
        if session.pendingScene != nil {
            if !conflicted, diskChangedOutsideWisp() { conflicted = true }
            if conflicted {
                saveRecoveryCopy()
            } else {
                writePending()
                conflicted = externalChangePending
                if conflicted { saveRecoveryCopy() }
            }
        }
        if editedThisSession, !conflicted, var current = file, current.pruneEmbeddedFiles() {
            let data = Data(current.serialized().utf8)
            if (try? AtomicFile.write(data, to: url, root: brainRoot, expectingHash: state.knownDiskHash)) != nil { state.didWrite(data) }
        }
        host.tearDown()
        if let quitToken { QuitFlush.shared.unregister(quitToken) }
        quitToken = nil
        closer.finish()
    }

    private func diskChangedOutsideWisp() -> Bool {
        guard let onDisk = try? Data(contentsOf: url) else { return false }
        var probe = state
        probe.dirty = true
        return probe.externalChange(diskData: onDisk) == .prompt
    }

    private func saveRecoveryCopy() {
        guard let scene = session.pendingScene, var current = file else { return }
        do {
            try current.apply(sceneJSON: scene, store: storeAttachment)
            let destination = DrawingRecovery.recoveryURL(for: url)
            try AtomicFile.write(Data(current.serialized().utf8), to: destination, root: brainRoot)
            session.discardPending()
            onNotice("\(url.lastPathComponent) mudou fora do Wisp. Suas edições foram salvas em \(destination.lastPathComponent).")
        } catch {
            log.error("drawing recovery failed: \(error.localizedDescription, privacy: .public)")
            onNotice("Não consegui salvar suas edições de \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func setDark(_ value: Bool) {
        dark = value
        if pageReady { host.send(.setTheme(dark: value)) }
    }

    func export(_ format: DrawingExportFormat) {
        host.send(.export(format))
    }

    private var brainRoot: URL { DrawingAttachments.root(for: url, vaultRoot: vaultRoot) }

    private func storeAttachment(_ attachment: ExcalidrawFile.NewAttachment) throws -> String {
        let target = DrawingAttachments.uniqueURL(forPastedImage: attachment.mimeType, in: url.deletingLastPathComponent())
        try AtomicFile.write(attachment.data, to: target, root: brainRoot)
        return target.lastPathComponent
    }

    func reloadFromDisk() {
        session.didReload()
        externalChangePending = false
        loadFromDisk()
    }

    func overwriteDisk() {
        externalChangePending = false
        writePending(force: true)
    }

    private func perform(_ actions: [DrawingEditSession.Action]) {
        for action in actions {
            switch action {
            case .requestSave: host.send(.requestSave)
            case .setViewMode(let viewMode): host.send(.setViewMode(viewMode))
            case .scheduleAutosave:
                editedThisSession = true
                saveNote = "Editando…"
                scheduleAutosave()
            case .cancelAutosave: autosave?.cancel()
            case .writeNow:
                editedThisSession = true
                writePending()
            }
        }
    }

    private func handle(_ event: DrawingBridgeEvent) {
        switch event {
        case .ready:
            pageReady = true
            loadFromDisk()
        case .dirty, .clean, .changed, .save:
            guard readOnlyNotice == nil else { return }
            let before = session.hasUnsavedWork
            perform(session.handle(event))
            if session.hasUnsavedWork, !before { state.dirty = true }
        case .exported(let format, let data):
            saveExport(data, format: format)
        case .openLink(let link):
            open(link)
        case .failure(let message):
            log.error("drawing web error: \(message, privacy: .public)")
            if status == .loading { status = .failed(message) }
        case .log(let message):
            log.debug("drawing web: \(message, privacy: .public)")
        }
    }

    private func loadFromDisk() {
        do {
            let data = try Data(contentsOf: url)
            let parsed = try ExcalidrawFile.parse(data: data, container: ExcalidrawFile.container(forFileNamed: url.lastPathComponent) ?? .markdown)
            file = parsed
            readOnlyNotice = parsed.readOnlyNotice
            if parsed.readOnlyNotice != nil { editing = false }
            state.didLoad(data)
            session.didReload()
            loadGeneration += 1
            let generation = loadGeneration
            let location = url
            let vault = vaultRoot
            let viewMode = !editing
            let isDark = dark
            Task { [weak self] in
                let files = await Self.embeddedFiles(of: parsed, near: location, vaultRoot: vault)
                guard let self, generation == self.loadGeneration, !self.closing else { return }
                self.host.send(.load(scene: parsed.scene.serialized(), files: files, viewMode: viewMode, dark: isDark, language: "pt-BR"))
                self.status = .ready
                self.saveNote = ""
            }
        } catch {
            status = .failed((error as? ExcalidrawFile.ParseError)?.description ?? error.localizedDescription)
        }
    }

    private nonisolated static func embeddedFiles(of file: ExcalidrawFile, near location: URL, vaultRoot: URL?) async -> JSONValue {
        guard file.container == .markdown else { return .object([]) }
        var resolved: [String: URL] = [:]
        for entry in file.embeddedFiles {
            guard let target = ExcalidrawFile.wikilinkTarget(of: entry), ExcalidrawFile.mimeType(forFileNamed: target) != nil,
                  let found = await DrawingAttachments.resolve(target: target, near: location, vaultRoot: vaultRoot, index: .shared) else { continue }
            resolved[target] = found
        }
        let table = resolved
        return await Task.detached { file.filesPayload { table[$0] } }.value
    }

    private func scheduleAutosave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.writePending()
        }
    }

    private func writePending(force: Bool = false) {
        guard readOnlyNotice == nil, let scene = session.pendingScene, var current = file else { return }
        if !force {
            guard !externalChangePending else { return }
            state.dirty = true
            if let onDisk = try? Data(contentsOf: url), state.externalChange(diskData: onDisk) == .prompt {
                externalChangePending = true
                return
            }
        }
        do {
            try current.apply(sceneJSON: scene, store: storeAttachment)
            let text = Data(current.serialized().utf8)
            try AtomicFile.write(text, to: url, root: brainRoot, expectingHash: force ? nil : state.knownDiskHash)
            file = current
            state.didWrite(text)
            session.didWrite()
            saveNote = current.notices.first ?? "Salvo"
        } catch AtomicFile.Failure.changedOnDisk {
            state.dirty = true
            externalChangePending = true
        } catch {
            saveNote = "Não consegui salvar: \((error as? AtomicFile.Failure)?.description ?? error.localizedDescription)"
            log.error("drawing save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func checkDisk() {
        guard status == .ready, !externalChangePending else { return }
        state.dirty = session.hasUnsavedWork
        switch state.externalChange(diskData: try? Data(contentsOf: url)) {
        case .none: break
        case .reload: loadFromDisk()
        case .prompt: externalChangePending = true
        }
    }

    private func open(_ link: String) {
        switch DrawingLink.parse(link) {
        case .note(let target, let heading):
            openNote(heading.map { "\(target)#\($0)" } ?? target)
        case .url(let destination):
            NSWorkspace.shared.open(destination)
        case nil:
            break
        }
    }

    private func saveExport(_ data: Data, format: DrawingExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .svg ? .svg : .png]
        panel.nameFieldStringValue = url.deletingPathExtension().deletingPathExtension().lastPathComponent + "." + format.fileExtension
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }
}
