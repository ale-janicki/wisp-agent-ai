import AppKit
import Combine
import ImageIO
import os
import UniformTypeIdentifiers
import WispCore

@MainActor
final class ClipboardService: ObservableObject {
    @Published private(set) var history: ClipboardHistory
    @Published private(set) var notice: String?

    private let store: ClipboardStore
    private let pasteboard = NSPasteboard.general
    private let writeQueue = DispatchQueue(label: "com.owner.wisp.clipboard.write", qos: .utility)
    private var lastChangeCount: Int
    private var poll: Timer?
    private var expiry: Timer?
    private var persists = true
    private let log = Logger(subsystem: "com.owner.wisp", category: "clipboard")

    private static let interval: TimeInterval = 0.5
    private static let expiryInterval: TimeInterval = 600
    private static let maxImageBytes = 25_000_000
    private static let thumbnailPixels = 160

    init(store: ClipboardStore = ClipboardStore()) {
        self.store = store
        history = store.load()
        notice = store.lastRecoveryNote
        lastChangeCount = NSPasteboard.general.changeCount
        expireOld()
    }

    var captureEnabled: Bool { AppSettings.shared.settings.clipboardCapture }

    func start() {
        guard poll == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        poll = timer

        let sweep = Timer(timeInterval: Self.expiryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireOld() }
        }
        sweep.tolerance = 30
        RunLoop.main.add(sweep, forMode: .common)
        expiry = sweep
    }

    func setCapture(_ on: Bool) {
        AppSettings.shared.setClipboardCapture(on)
    }

    // MARK: Actions

    func copy(_ item: ClipItem) {
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .url:
            let text = item.text ?? ""
            if let url = URL(string: text) { pasteboard.writeObjects([url as NSURL]) }
            pasteboard.setString(text, forType: .string)
        case .image:
            if let name = item.image, let data = try? Data(contentsOf: store.url(of: name)) {
                pasteboard.setData(data, forType: .png)
            }
        }
        lastChangeCount = pasteboard.changeCount
        var touched = item
        touched.copiedAt = Date()
        add(touched)
    }

    func togglePin(_ item: ClipItem) {
        history.togglePin(item.id)
        save()
    }

    func remove(_ item: ClipItem) {
        guard let removed = history.remove(item.id) else { return }
        deleteFiles([removed])
        save()
    }

    func clearUnpinned() {
        deleteFiles(history.clearUnpinned())
        save()
    }

    func thumbnailURL(of item: ClipItem) -> URL? {
        item.image.map { store.url(of: ClipItem.thumbnailName(for: $0)) }
    }

    // MARK: Capture

    private func check() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard captureEnabled else { return }
        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard ClipboardPrivacy.shouldCapture(types: types) else { return }

        if let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let data = Data(string.utf8)
            guard data.count <= ClipboardHistory.maxTextBytes else { return }
            add(ClipItem(kind: ClipItem.kind(of: string), text: string, image: nil, fingerprint: ClipItem.fingerprint(data), copiedAt: Date()))
        } else if let raw = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), raw.count <= Self.maxImageBytes {
            captureImage(raw)
        }
    }

    private func captureImage(_ raw: Data) {
        guard persists else { return }
        let fingerprint = ClipItem.fingerprint(raw)
        if history.contains(fingerprint: fingerprint) {
            add(ClipItem(kind: .image, text: nil, image: nil, fingerprint: fingerprint, copiedAt: Date()))
            return
        }
        let store = store
        let id = UUID()
        let pixels = Self.thumbnailPixels
        Task.detached(priority: .utility) { [weak self] in
            guard let (png, thumbnail) = Self.encode(raw, thumbnailPixels: pixels),
                  let name = try? store.writeImage(png: png, thumbnail: thumbnail, id: id) else { return }
            let item = ClipItem(id: id, kind: .image, text: nil, image: name, fingerprint: fingerprint, copiedAt: Date())
            await self?.add(item)
        }
    }

    nonisolated private static func encode(_ raw: Data, thumbnailPixels: Int) -> (png: Data, thumbnail: Data)? {
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let png = pngData(full), let thumbnail = pngData(thumb) else { return nil }
        return (png, thumbnail)
    }

    nonisolated private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func add(_ item: ClipItem) {
        deleteFiles(history.insert(item))
        deleteFiles(history.expire(now: Date()))
        save()
    }

    private func expireOld() {
        let expired = history.expire(now: Date())
        guard !expired.isEmpty else { return }
        deleteFiles(expired)
        save()
    }

    // MARK: Disk

    private func deleteFiles(_ items: [ClipItem]) {
        guard persists, !items.isEmpty else { return }
        let store = store
        writeQueue.async { store.deleteFiles(of: items) }
    }

    private func save() {
        guard persists else { return }
        let snapshot = history
        let store = store
        writeQueue.async { [weak self] in
            do {
                try store.save(snapshot)
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.log.error("clipboard save failed: \(message, privacy: .public)")
                    self?.notice = "Não consegui salvar os copiados: \(message)"
                }
            }
        }
    }

    #if DEBUG
    func captureForSnapshot() {
        persists = false
        lastChangeCount = -1
        check()
    }
    #endif
}
