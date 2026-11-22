import AppKit
import SwiftUI
import WispCore

struct BrainDrawingView: View {
    let url: URL
    var vaultRoot: URL?
    var onOpenNote: (String) -> Void = { _ in }
    var onNotice: (String) -> Void = DrawingNotices.alert

    static func supports(_ url: URL) -> Bool {
        ExcalidrawFile.container(forFileNamed: url.lastPathComponent) != nil || url.pathExtension.lowercased() == "canvas"
    }

    var body: some View {
        Group {
            if url.pathExtension.lowercased() == "canvas" {
                BrainCanvasView(url: url, vaultRoot: vaultRoot, onOpenNote: onOpenNote, onNotice: onNotice)
            } else if ExcalidrawFile.container(forFileNamed: url.lastPathComponent) != nil {
                ExcalidrawDocumentView(url: url, vaultRoot: vaultRoot, onOpenNote: onOpenNote, onNotice: onNotice)
            } else {
                InlineError(text: "O Wisp não abre \(url.lastPathComponent) como desenho.")
                    .padding(Theme.Space.l)
            }
        }
        .id(url)
    }
}

private struct ExcalidrawDocumentView: View {
    let url: URL
    let vaultRoot: URL?
    let onOpenNote: (String) -> Void
    let onNotice: (String) -> Void
    @State private var model: BrainDrawingModel?

    private var isDark: Bool { DrawingTheme.isDark }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            if let model {
                DrawingToolbar(title: url.lastPathComponent, editing: Binding(get: { model.editing }, set: { model.editing = $0 }), note: model.saveNote) {
                    Menu {
                        Button("Exportar PNG…") { model.export(.png) }
                        Button("Exportar SVG…") { model.export(.svg) }
                    } label: {
                        Text("Exportar")
                    }
                    .menuStyle(.button)
                    .buttonStyle(CompactCapsuleStyle(accent: false))
                    .fixedSize()
                }
                if model.externalChangePending {
                    ExternalChangeBanner(reload: model.reloadFromDisk, overwrite: model.overwriteDisk)
                }
                if case .failed(let message) = model.status {
                    InlineError(text: message)
                }
                DrawingWebHostView(host: model.host)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
                    .opacity(model.status == .ready ? 1 : 0.01)
                    .onChange(of: isDark) { _, dark in model.setDark(dark) }
            } else {
                Spacer()
            }
        }
        .padding(Theme.Space.m)
        .task(id: url) {
            model?.stop()
            let next = BrainDrawingModel(url: url, vaultRoot: vaultRoot, dark: isDark, openNote: onOpenNote, onNotice: onNotice)
            model = next
            next.start()
        }
        .onDisappear { model?.stop() }
    }
}

enum DrawingNotices {
    static func alert(_ message: String) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "Desenho"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

enum DrawingTheme {
    @MainActor static var isDark: Bool {
        let color = AppSettings.shared.colors.background
        let luminance = 0.2126 * Double(color.red) + 0.7152 * Double(color.green) + 0.0722 * Double(color.blue)
        return luminance < 128
    }
}

struct DrawingToolbar<Trailing: View>: View {
    let title: String
    @Binding var editing: Bool
    var note: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !note.isEmpty {
                Text(note)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                Button("Ver") { editing = false }
                    .buttonStyle(CompactCapsuleStyle(accent: !editing))
                Button("Editar") { editing = true }
                    .buttonStyle(CompactCapsuleStyle(accent: editing))
            }
            trailing
        }
    }
}

struct ExternalChangeBanner: View {
    let reload: () -> Void
    let overwrite: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Circle().fill(Theme.busy).frame(width: 7, height: 7)
            Text("O arquivo mudou fora do Wisp enquanto você editava.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            Button("Recarregar do disco", action: reload)
                .buttonStyle(CompactCapsuleStyle(accent: false))
            Button("Manter o meu", action: overwrite)
                .buttonStyle(CompactCapsuleStyle(accent: true))
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 7)
        .background(Theme.busy.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
    }
}

struct BrainDrawingEmbedView: View {
    let url: URL
    var revision = 0
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Label("Não consegui desenhar \(url.lastPathComponent)", systemImage: "scribble")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Skeleton().frame(height: 80)
            }
        }
        .task(id: "\(url.path)|\(revision)") {
            do {
                if let svg = try await DrawingEmbedCache.shared.svg(for: url), let rendered = NSImage(data: Data(svg.utf8)) {
                    image = rendered
                    failed = false
                } else {
                    image = nil
                    failed = true
                }
            } catch {
                image = nil
                failed = true
            }
        }
    }
}
