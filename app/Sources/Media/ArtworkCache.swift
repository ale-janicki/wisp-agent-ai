import AppKit
import SwiftUI

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private var images: [String: NSImage] = [:]
    private var order: [String] = []
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private var failures: [URL: Date] = [:]

    private static let limit = 200
    static let failureMemory: TimeInterval = 600

    func cached(_ url: URL) -> NSImage? {
        images[url.absoluteString]
    }

    func cached(key: String) -> NSImage? {
        images[key]
    }

    func store(_ image: NSImage, key: String) {
        if images[key] == nil { order.append(key) }
        images[key] = image
        while order.count > Self.limit {
            images[order.removeFirst()] = nil
        }
    }

    func image(for url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        guard url.scheme == "https" else { return nil }
        if let failed = failures[url] {
            if Date().timeIntervalSince(failed) < Self.failureMemory { return nil }
            failures[url] = nil
        }
        if let task = inFlight[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            let data = await Task.detached(priority: .utility) { () -> Data? in
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 300
                else { return nil }
                return data
            }.value
            return data.flatMap(NSImage.init(data:))
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { store(image, key: url.absoluteString) } else { failures[url] = Date() }
        return image
    }
}

struct RemoteArtwork: View {
    let url: URL?
    var size: CGFloat
    var radius: CGFloat = Theme.Radius.artwork
    var placeholder = "music.note"

    @State private var image: NSImage?
    @State private var loading = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loading {
                Skeleton(cornerRadius: radius)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surfaceHi)
                    .overlay {
                        Image(systemName: placeholder)
                            .font(.system(size: size * 0.36, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            loading = false
            return
        }
        if let cached = ArtworkCache.shared.cached(url) {
            image = cached
            return
        }
        image = nil
        loading = true
        let fetched = await ArtworkCache.shared.image(for: url)
        guard !Task.isCancelled else { return }
        image = fetched
        loading = false
    }
}
