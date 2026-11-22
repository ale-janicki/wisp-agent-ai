import AppKit
import Observation
import os
import SwiftUI
import WispCore

@MainActor @Observable
final class BrainCanvasModel {
    enum Status: Equatable {
        case loading
        case ready
        case failed(String)
    }

    struct Dragging: Equatable {
        var ids: [String]
        var delta: CGSize
    }

    let url: URL
    private(set) var canvas = JSONCanvas.blank()
    private(set) var status = Status.loading
    private(set) var saveNote = ""
    private(set) var externalChangePending = false
    private(set) var readOnlyNotice: String?
    var editing = false {
        didSet {
            if !editing { connectingFrom = nil }
            if editing, readOnlyNotice != nil { editing = false }
        }
    }
    var selection: String?
    var connectingFrom: String?
    var dragging: Dragging?
    var scale: CGFloat = 1
    var pan = CGSize.zero
    var viewport = CGSize.zero

    @ObservationIgnored let vaultRoot: URL?
    @ObservationIgnored let openNote: (String) -> Void
    @ObservationIgnored let onNotice: (String) -> Void
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var imageTask: Task<Void, Never>?
    @ObservationIgnored private var state = DrawingFileState()
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var fitted = false
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "drawings")

    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 4

    init(url: URL, vaultRoot: URL?, openNote: @escaping (String) -> Void, onNotice: @escaping (String) -> Void) {
        self.url = url
        self.vaultRoot = vaultRoot
        self.openNote = openNote
        self.onNotice = onNotice
    }

    func start() {
        load()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                self?.checkDisk()
            }
        }
    }

    func stop() {
        autosave?.cancel()
        watcher?.cancel()
        imageTask?.cancel()
        guard state.dirty else { return }
        let onDisk = try? Data(contentsOf: url)
        let conflicted = externalChangePending || (onDisk != nil && state.externalChange(diskData: onDisk) == .prompt)
        if conflicted {
            saveRecoveryCopy()
        } else {
            writeNow()
        }
    }

    private func saveRecoveryCopy() {
        let destination = DrawingRecovery.recoveryURL(for: url)
        do {
            try canvas.write(to: destination, root: brainRoot)
            state.dirty = false
            onNotice("\(url.lastPathComponent) mudou fora do Wisp. Suas edições foram salvas em \(destination.lastPathComponent).")
        } catch {
            log.error("canvas recovery failed: \(error.localizedDescription, privacy: .public)")
            onNotice("Não consegui salvar suas edições de \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func reloadFromDisk() {
        externalChangePending = false
        state.dirty = false
        load()
    }

    func overwriteDisk() {
        externalChangePending = false
        writeNow(force: true)
    }

    private func load() {
        do {
            let data = try Data(contentsOf: url)
            canvas = try JSONCanvas.parse(data: data)
            readOnlyNotice = canvas.readOnlyNotice
            if readOnlyNotice != nil { editing = false }
            state.didLoad(data)
            status = .ready
            saveNote = ""
            if !fitted, viewport.width > 0 { fit() }
            loadImages()
        } catch {
            status = .failed((error as? JSONCanvas.CanvasError)?.description ?? error.localizedDescription)
        }
    }

    private func checkDisk() {
        guard status == .ready, !externalChangePending else { return }
        switch state.externalChange(diskData: try? Data(contentsOf: url)) {
        case .none: break
        case .reload: load()
        case .prompt: externalChangePending = true
        }
    }

    private var brainRoot: URL { DrawingAttachments.root(for: url, vaultRoot: vaultRoot) }

    func mutate(_ change: (inout JSONCanvas) -> Void) {
        guard readOnlyNotice == nil else { return }
        change(&canvas)
        state.dirty = true
        saveNote = "Editando…"
        autosave?.cancel()
        autosave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    private func writeNow(force: Bool = false) {
        if !force {
            guard !externalChangePending else { return }
            if let onDisk = try? Data(contentsOf: url), state.externalChange(diskData: onDisk) == .prompt {
                externalChangePending = true
                return
            }
        }
        do {
            let data = Data(canvas.serialized().utf8)
            try AtomicFile.write(data, to: url, root: brainRoot, expectingHash: force ? nil : state.knownDiskHash)
            state.didWrite(data)
            saveNote = "Salvo"
        } catch AtomicFile.Failure.changedOnDisk {
            state.dirty = true
            externalChangePending = true
        } catch {
            saveNote = "Não consegui salvar: \(error.localizedDescription)"
            log.error("canvas save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setViewport(_ size: CGSize) {
        viewport = size
        if !fitted, status == .ready, size.width > 0 { fit() }
    }

    func fit() {
        guard let bounds = canvas.bounds, viewport.width > 0, viewport.height > 0 else { return }
        let margin: CGFloat = 40
        let sx = (viewport.width - margin * 2) / max(1, bounds.width)
        let sy = (viewport.height - margin * 2) / max(1, bounds.height)
        scale = min(max(min(sx, sy, 1.5), Self.minScale), Self.maxScale)
        pan = CGSize(
            width: (viewport.width - bounds.width * scale) / 2 - bounds.x * scale,
            height: (viewport.height - bounds.height * scale) / 2 - bounds.y * scale
        )
        fitted = true
    }

    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        let target = min(max(scale * factor, Self.minScale), Self.maxScale)
        let point = anchor ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let worldX = (point.x - pan.width) / scale
        let worldY = (point.y - pan.height) / scale
        scale = target
        pan = CGSize(width: point.x - worldX * target, height: point.y - worldY * target)
    }

    func screenOrigin(of node: CanvasNode) -> CGPoint {
        let shift = dragging.flatMap { $0.ids.contains(node.id) ? $0.delta : nil } ?? .zero
        return CGPoint(x: (node.x + shift.width) * scale + pan.width, y: (node.y + shift.height) * scale + pan.height)
    }

    func beginDrag(of node: CanvasNode) -> [String] {
        var ids = [node.id]
        if node.kind == .group {
            ids += canvas.nodes.filter { $0.id != node.id && node.contains($0) }.map(\.id)
        }
        return ids
    }

    func commitDrag() {
        guard let drag = dragging else { return }
        dragging = nil
        let dx = (drag.delta.width / scale).rounded()
        let dy = (drag.delta.height / scale).rounded()
        guard dx != 0 || dy != 0 else { return }
        mutate { canvas in
            for id in drag.ids {
                guard let node = canvas.node(id) else { continue }
                canvas.moveNode(id, to: (node.x + dx, node.y + dy))
            }
        }
    }

    func addNode(_ kind: CanvasNode.Kind, text: String = "") {
        let centerX = (viewport.width / 2 - pan.width) / scale
        let centerY = (viewport.height / 2 - pan.height) / scale
        let size: (Double, Double) = kind == .group ? (400, 260) : (260, kind == .text ? 120 : 80)
        let node = CanvasNode(
            id: JSONCanvas.newID(), kind: kind,
            x: (centerX - size.0 / 2).rounded(), y: (centerY - size.1 / 2).rounded(),
            width: size.0, height: size.1,
            text: kind == .text ? text : nil, file: kind == .file ? text : nil, url: kind == .link ? text : nil,
            label: kind == .group ? (text.isEmpty ? "Grupo" : text) : nil
        )
        mutate { $0.add(node) }
        selection = node.id
    }

    func deleteSelection() {
        guard let id = selection else { return }
        selection = nil
        mutate { $0.removeNode(id) }
    }

    func setText(_ text: String, for id: String) {
        mutate { canvas in
            guard let index = canvas.nodes.firstIndex(where: { $0.id == id }) else { return }
            if canvas.nodes[index].kind == .group { canvas.nodes[index].label = text } else { canvas.nodes[index].text = text }
        }
    }

    func resize(_ id: String, to size: CGSize) {
        mutate { $0.resizeNode(id, width: (size.width / scale).rounded(), height: (size.height / scale).rounded()) }
    }

    func tap(_ node: CanvasNode) {
        if editing, let source = connectingFrom {
            connectingFrom = nil
            mutate { $0.connect(from: source, to: node.id) }
            return
        }
        selection = node.id
        if !editing { activate(node) }
    }

    func activate(_ node: CanvasNode) {
        switch node.kind {
        case .file:
            if let target = node.linkTarget { openNote(target) }
        case .link:
            if let raw = node.url, let destination = URL(string: raw), ["http", "https", "mailto"].contains(destination.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(destination)
            }
        default:
            break
        }
    }

    private func loadImages() {
        imageTask?.cancel()
        let nodes = canvas.nodes.filter { $0.kind == .file && ExcalidrawFile.mimeType(forFileNamed: $0.file ?? "") != nil }
        guard !nodes.isEmpty else {
            images = [:]
            return
        }
        let location = url
        let vault = vaultRoot
        imageTask = Task { [weak self] in
            var loaded: [String: Data] = [:]
            for node in nodes {
                guard let path = node.file,
                      let found = await DrawingAttachments.resolve(target: path, near: location, vaultRoot: vault, index: .shared),
                      let data = await Task.detached(operation: { try? Data(contentsOf: found) }).value else { continue }
                loaded[node.id] = data
            }
            guard !Task.isCancelled, let self else { return }
            self.images = loaded.compactMapValues { NSImage(data: $0) }
        }
    }
}
