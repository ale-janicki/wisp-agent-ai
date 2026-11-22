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
    var editing = false {
        didSet { if editing != oldValue { editingChanged() } }
    }

    @ObservationIgnored private let vaultRoot: URL?
    @ObservationIgnored private let openNote: (String) -> Void
    @ObservationIgnored private let onNotice: (String) -> Void
    @ObservationIgnored private var webDirty = false
    @ObservationIgnored private var editedThisSession = false
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var file: ExcalidrawFile?
    @ObservationIgnored private var state = DrawingFileState()
    @ObservationIgnored private var pendingScene: String?
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
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                self?.checkDisk()
            }
        }
    }

    func stop() {
        guard !closing else { return }
        closing = true
        autosave?.cancel()
        watcher?.cancel()
        if editing, webDirty, pageReady {
            host.send(.requestSave)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.finishClosing()
            }
        } else {
            finishClosing()
        }
    }

    private func finishClosing() {
        var conflicted = externalChangePending
        if pendingScene != nil {
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
            if (try? data.write(to: url, options: .atomic)) != nil { state.didWrite(data) }
        }
        host.tearDown()
    }

    private func diskChangedOutsideWisp() -> Bool {
        guard let onDisk = try? Data(contentsOf: url) else { return false }
        var probe = state
        probe.dirty = true
        return probe.externalChange(diskData: onDisk) == .prompt
    }

    private func saveRecoveryCopy() {
        guard let scene = pendingScene, var current = file else { return }
        let folder = url.deletingLastPathComponent()
        do {
            try current.apply(sceneJSON: scene) { attachment in
                let target = DrawingAttachments.uniqueURL(forPastedImage: attachment.mimeType, in: folder)
                try attachment.data.write(to: target, options: .atomic)
                return target.lastPathComponent
            }
            let destination = DrawingRecovery.recoveryURL(for: url)
            try Data(current.serialized().utf8).write(to: destination, options: .atomic)
            pendingScene = nil
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

    func reloadFromDisk() {
        pendingScene = nil
        webDirty = false
        externalChangePending = false
        loadFromDisk()
    }

    func overwriteDisk() {
        externalChangePending = false
        writePending(force: true)
    }

    private func editingChanged() {
        guard pageReady else { return }
        host.send(.setViewMode(!editing))
        if !editing, pendingScene != nil { writePending() }
    }

    private func handle(_ event: DrawingBridgeEvent) {
        switch event {
        case .ready:
            pageReady = true
            loadFromDisk()
        case .dirty:
            guard editing else { return }
            webDirty = true
            state.dirty = true
        case .clean:
            if pendingScene == nil { webDirty = false }
        case .changed(let scene):
            guard editing else { return }
            webDirty = true
            editedThisSession = true
            pendingScene = scene
            saveNote = "Editando…"
            scheduleAutosave()
        case .save(let scene):
            guard editing else { return }
            editedThisSession = true
            pendingScene = scene
            autosave?.cancel()
            writePending()
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
            let parsed = try ExcalidrawFile.parse(String(decoding: data, as: UTF8.self), container: ExcalidrawFile.container(forFileNamed: url.lastPathComponent) ?? .markdown)
            file = parsed
            state.didLoad(data)
            webDirty = false
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
        guard let scene = pendingScene, var current = file else { return }
        if !force {
            guard !externalChangePending else { return }
            state.dirty = true
            if let onDisk = try? Data(contentsOf: url), state.externalChange(diskData: onDisk) == .prompt {
                externalChangePending = true
                return
            }
        }
        do {
            let folder = url.deletingLastPathComponent()
            try current.apply(sceneJSON: scene) { attachment in
                let target = DrawingAttachments.uniqueURL(forPastedImage: attachment.mimeType, in: folder)
                try attachment.data.write(to: target, options: .atomic)
                return target.lastPathComponent
            }
            let text = Data(current.serialized().utf8)
            try text.write(to: url, options: .atomic)
            file = current
            state.didWrite(text)
            pendingScene = nil
            webDirty = false
            saveNote = current.notices.first ?? "Salvo"
        } catch {
            saveNote = "Não consegui salvar: \(error.localizedDescription)"
            log.error("drawing save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func checkDisk() {
        guard status == .ready, !externalChangePending else { return }
        state.dirty = pendingScene != nil || webDirty
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
