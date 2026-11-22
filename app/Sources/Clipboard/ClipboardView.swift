import AppKit
import SwiftUI
import WispCore

struct ClipboardView: View {
    @ObservedObject var clipboard: ClipboardService
    @State private var query = ""
    @State private var confirmingClear = false
    @State private var copiedId: UUID?
    @State private var copiedTask: Task<Void, Never>?
    private let settings = AppSettings.shared

    private var hasUnpinned: Bool { clipboard.history.items.contains { !$0.pinned } }
    private var hasPinned: Bool { clipboard.history.items.contains(where: \.pinned) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardGap) {
            HStack(spacing: Theme.Space.m) {
                Text("Copiados")
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if confirmingClear {
                    Text(hasPinned ? "Limpar o histórico? Os fixados ficam." : "Limpar todo o histórico?")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Sim") {
                        clipboard.clearUnpinned()
                        confirmingClear = false
                    }
                    .buttonStyle(CapsuleButtonStyle(kind: .error))
                    Button("Não") { confirmingClear = false }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                } else {
                    Button("Limpar") { confirmingClear = true }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                        .disabled(!hasUnpinned)
                }
            }
            searchField
            if !settings.settings.clipboardCapture {
                HStack(spacing: Theme.Space.m) {
                    Text("A captura está desligada; ligue para guardar o que você copiar.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.busy)
                    Button("Ligar") { clipboard.setCapture(true) }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            }
            if let notice = clipboard.notice {
                Text(notice)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.busy)
            }
            list
        }
        .padding(.top, Theme.Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            TextField("Buscar nos copiados", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 36)
        .background(Theme.surfaceHi, in: Capsule())
    }

    @ViewBuilder
    private var list: some View {
        let items = clipboard.history.visible(matching: query)
        if items.isEmpty {
            Text(clipboard.history.items.isEmpty ? "Nada copiado ainda" : "Nada encontrado")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        ClipRow(
                            item: item,
                            thumbnail: clipboard.thumbnailURL(of: item),
                            copied: copiedId == item.id,
                            copy: { copy(item) },
                            pin: { clipboard.togglePin(item) },
                            remove: { clipboard.remove(item) }
                        )
                    }
                }
                .padding(Theme.Space.s)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .card()
        }
    }

    private func copy(_ item: ClipItem) {
        clipboard.copy(item)
        copiedId = item.id
        copiedTask?.cancel()
        copiedTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedId = nil
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let thumbnail: URL?
    let copied: Bool
    let copy: () -> Void
    let pin: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    private static let height: CGFloat = 48
    private static let icon: CGFloat = 32

    var body: some View {
        Button(action: copy) {
            HStack(spacing: Theme.Space.m) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(preview)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(copied ? "copiado" : caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(copied ? Theme.accentText : Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.trailing, hovering || item.pinned ? 64 : 0)
        }
        .buttonStyle(RowButtonStyle(height: Self.height, hovered: hovering))
        .overlay(alignment: .trailing) {
            HStack(spacing: Theme.Space.xs) {
                if hovering || item.pinned {
                    Button(action: pin) {
                        Image(systemName: item.pinned ? "pin.fill" : "pin")
                            .foregroundStyle(item.pinned ? Theme.accent : Theme.textPrimary)
                    }
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .help(item.pinned ? "Desafixar" : "Fixar")
                }
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .help("Remover")
                }
            }
            .padding(.trailing, Theme.Space.s)
        }
        .onHover { hovering = $0 }
        .help(item.text ?? "Imagem")
    }

    @ViewBuilder
    private var leading: some View {
        if item.kind == .image, let thumbnail {
            ClipThumbnail(url: thumbnail, size: Self.icon)
        } else {
            Image(systemName: item.kind == .url ? "link" : "doc.plaintext")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Self.icon, height: Self.icon)
                .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
        }
    }

    private var preview: String {
        guard let text = item.text else { return "Imagem" }
        return text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? text
    }

    private var caption: String {
        let when = Self.relative(item.copiedAt)
        switch item.kind {
        case .text:
            let lines = item.text?.split(whereSeparator: \.isNewline).count ?? 1
            return lines > 1 ? "\(when) · \(lines) linhas" : when
        case .url: return "\(when) · link"
        case .image: return "\(when) · imagem"
        }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relative(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? "agora" : formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ClipThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Skeleton()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
        .task(id: url) {
            let url = url
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
