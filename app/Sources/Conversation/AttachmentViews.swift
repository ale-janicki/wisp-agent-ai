import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WispCore

/// Downsampled thumbnails, decoded off the main thread with ImageIO; never a full-size decode.
@MainActor
final class AttachmentThumbnails {
    enum Thumb {
        case image(NSImage)
        /// No file at that path (e.g. it arrived on the other machine).
        case missing
        /// The file is there but ImageIO cannot decode it.
        case undecodable
    }

    static let shared = AttachmentThumbnails()

    private var cache: [String: Thumb] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<Thumb, Never>] = [:]

    private static let limit = 120

    func cached(_ path: String, maxPixel: Int) -> Thumb? {
        cache[Self.key(path, maxPixel)]
    }

    func thumbnail(_ path: String, maxPixel: Int) async -> Thumb {
        let key = Self.key(path, maxPixel)
        if let hit = cache[key] { return hit }
        if let task = inFlight[key] { return await task.value }
        let task = Task<Thumb, Never> {
            switch await Task.detached(priority: .utility, operation: { Self.decode(path, maxPixel: maxPixel) }).value {
            case .image(let decoded): return .image(NSImage(cgImage: decoded.image, size: .zero))
            case .missing: return .missing
            case .undecodable: return .undecodable
            }
        }
        inFlight[key] = task
        let thumb = await task.value
        inFlight[key] = nil
        if cache[key] == nil { order.append(key) }
        cache[key] = thumb
        while order.count > Self.limit { cache[order.removeFirst()] = nil }
        return thumb
    }

    private static func key(_ path: String, _ maxPixel: Int) -> String { "\(maxPixel)#\(path)" }

    private struct Decoded: @unchecked Sendable { let image: CGImage }

    private enum Outcome: Sendable {
        case image(Decoded)
        case missing
        case undecodable
    }

    private nonisolated static func decode(_ path: String, maxPixel: Int) -> Outcome {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return .undecodable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { .image(Decoded(image: $0)) } ?? .undecodable
    }
}

/// Photos and files of one user message, Telegram style: big rounded images stacked, file chips, no paths.
struct AttachmentStack: View {
    let attachments: MessageAttachments
    let time: Date?
    let maxWidth: CGFloat

    private var images: [(path: String, name: String, bytes: Int)] {
        attachments.items.compactMap { item in
            guard case .file(let path, let name, let bytes) = item, MessageAttachments.isImage(name) else { return nil }
            return (path, name, bytes)
        }
    }

    private var others: [MessageAttachments.Item] {
        attachments.items.filter { item in
            if case .file(_, let name, _) = item { return !MessageAttachments.isImage(name) }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                ImageTile(path: image.path, name: image.name, bytes: image.bytes, maxWidth: maxWidth,
                          time: index == images.count - 1 && others.isEmpty && attachments.caption == nil ? time : nil)
            }
            ForEach(Array(others.enumerated()), id: \.offset) { _, item in
                FileChip(item: item)
            }
        }
    }
}

private struct ImageTile: View {
    let path: String
    let name: String
    let bytes: Int
    let maxWidth: CGFloat
    let time: Date?

    @State private var thumb: AttachmentThumbnails.Thumb?
    @Environment(\.displayScale) private var scale

    private var maxPixel: Int { Int((maxWidth * scale).rounded(.up)) }
    private var maxHeight: CGFloat { maxWidth * 1.25 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous) }

    var body: some View {
        Group {
            switch thumb ?? AttachmentThumbnails.shared.cached(path, maxPixel: maxPixel) {
            case .image(let image)?:
                let size = fitted(image)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(shape)
                    .overlay(alignment: .bottomTrailing) { if let time { TimeBadge(time: time) } }
                    .contentShape(shape)
                    .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .pointerStyle(.link)
                    .help("Abrir")
            case .missing?:
                VStack(spacing: Theme.Space.xs) {
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .medium))
                    Text("foto no outro computador")
                        .font(Theme.Font.caption)
                }
                .foregroundStyle(Theme.textTertiary)
                .frame(width: maxWidth, height: maxWidth * 0.6)
                .background(Theme.surfaceHi, in: shape)
                .overlay(alignment: .bottomTrailing) { if let time { TimeBadge(time: time) } }
            case .undecodable?:
                FileChip(item: .file(path: path, name: name, bytes: bytes))
            case nil:
                Skeleton(cornerRadius: Theme.Radius.bubble)
                    .frame(width: maxWidth, height: maxWidth * 0.75)
            }
        }
        .task(id: "\(maxPixel)#\(path)") {
            thumb = await AttachmentThumbnails.shared.thumbnail(path, maxPixel: maxPixel)
        }
    }

    private func fitted(_ image: NSImage) -> CGSize {
        let pixels = image.size
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: maxWidth, height: maxWidth * 0.75) }
        let aspect = pixels.width / pixels.height
        let width = min(maxWidth, maxHeight * aspect)
        return CGSize(width: width, height: width / aspect)
    }
}

private struct TimeBadge: View {
    let time: Date

    var body: some View {
        Text(time.formatted(date: .omitted, time: .shortened))
            .font(Theme.Font.captionMono)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Theme.notch.opacity(0.5), in: Capsule())
            .padding(6)
    }
}

private struct FileChip: View {
    let item: MessageAttachments.Item

    @State private var present: Bool?

    var body: some View {
        switch item {
        case .file(let path, let name, let bytes):
            chip(icon: "doc.fill", title: MessageAttachments.displayName(name),
                 detail: present == false ? "no outro computador" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                .onTapGesture { if present == true { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
                .pointerStyle(present == true ? .link : nil)
                .task(id: path) {
                    present = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: path) }.value
                }
        case .failed(let label):
            chip(icon: "exclamationmark.triangle", title: label, detail: "não baixou")
        }
    }

    private func chip(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accentText)
                .frame(width: 32, height: 32)
                .background(Theme.accentFill, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.leading, Theme.Space.s)
        .padding(.trailing, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
    }
}

/// What the composer holds before sending: small removable tiles above the input.
struct PendingAttachmentsBar: View {
    let urls: [URL]
    let onRemove: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.s) {
                ForEach(urls, id: \.self) { url in
                    PendingTile(url: url) { onRemove(url) }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .scrollIndicators(.hidden)
    }
}

private struct PendingTile: View {
    let url: URL
    let onRemove: () -> Void

    @State private var thumb: AttachmentThumbnails.Thumb?
    @Environment(\.displayScale) private var scale

    private static let side: CGFloat = 52
    private var maxPixel: Int { Int((Self.side * scale).rounded(.up)) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous) }

    var body: some View {
        Group {
            if MessageAttachments.isImage(url.lastPathComponent), case .image(let image)? = thumb {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 2) {
                    Image(systemName: MessageAttachments.isImage(url.lastPathComponent) ? "photo" : "doc.fill")
                        .font(.system(size: 14, weight: .medium))
                    Text(url.pathExtension.uppercased())
                        .font(Theme.Font.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.stroke, lineWidth: 1) }
        .help(url.lastPathComponent)
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) { Image(systemName: "xmark") }
                .buttonStyle(CircleButtonStyle(kind: .filled, size: 18))
                .help("Remover")
                .offset(x: 6, y: -6)
        }
        .task(id: url) {
            guard MessageAttachments.isImage(url.lastPathComponent) else { return }
            thumb = await AttachmentThumbnails.shared.thumbnail(url.path, maxPixel: maxPixel)
        }
    }
}

enum AttachmentPicker {
    /// Images and files, several at once; nil when cancelled.
    @MainActor
    static func choose() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .data]
        panel.prompt = "Anexar"
        NSApp.activate()
        return panel.runModal() == .OK ? panel.urls : nil
    }

    /// An image on the clipboard (screenshot, copied photo) written to a temp file; Finder copies come as file URLs.
    @MainActor
    static func pasted(from board: NSPasteboard = .general, completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            completion(urls)
            return true
        }
        let png = board.data(forType: .png)
        guard let data = png ?? board.data(forType: .tiff) else { return false }
        let needsPNG = png == nil
        Task {
            let url = await Task.detached(priority: .userInitiated) { writePasted(data, transcode: needsPNG) }.value
            if let url { completion([url]) }
        }
        return true
    }

    private nonisolated static func writePasted(_ data: Data, transcode: Bool) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-colado-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("imagem-colada.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard transcode else {
                try data.write(to: url)
                return url
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
            return CGImageDestinationFinalize(destination) ? url : nil
        } catch {
            return nil
        }
    }
}
