import AppKit
import SwiftUI
import WispCore

struct FileCards: View {
    let paths: [String]
    let maxWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(paths, id: \.self) { path in
                FileCard(path: path, maxWidth: maxWidth)
            }
        }
    }
}

private struct FileCard: View {
    let path: String
    let maxWidth: CGFloat

    @State private var thumb: AttachmentThumbnails.Thumb?
    @State private var bytes: Int64?

    private var url: URL { URL(fileURLWithPath: path) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous) }
    private static let thumbSide: CGFloat = 220

    var body: some View {
        content
            .contentShape(shape)
            .onTapGesture { _ = MessageRow.openFile(url) }
            .pointerStyle(.link)
            .help("Abrir")
            .contextMenu {
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .task(id: path) {
                bytes = await Task.detached(priority: .utility) {
                    (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64
                }.value
                if SentFiles.isImage(path) {
                    thumb = await AttachmentThumbnails.shared.thumbnail(path, maxPixel: Int(Self.thumbSide * 2))
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if case .image(let image)? = thumb {
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: min(maxWidth, Self.thumbSide), height: Self.thumbSide * 0.7)
                    .clipped()
                label.padding(Theme.Space.s)
            }
            .frame(width: min(maxWidth, Self.thumbSide), alignment: .leading)
            .background(Theme.surfaceHi, in: shape)
            .clipShape(shape)
        } else {
            HStack(spacing: Theme.Space.s) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 32, height: 32)
                label
            }
            .padding(.leading, Theme.Space.s)
            .padding(.trailing, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.surfaceHi, in: shape)
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(url.lastPathComponent)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? " ")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
