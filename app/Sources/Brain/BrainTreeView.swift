import SwiftUI
import WispCore

struct BrainTreeView: View {
    var model: BrainModel
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Notas").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Button { model.prompt = .newNote(folder: model.active.map { BrainText.parent(of: $0.path) } ?? "") } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .help("Nova nota")
                Menu {
                    Button("Novo desenho") { model.createDrawing(.excalidraw, in: model.active.map { BrainText.parent(of: $0.path) } ?? "") }
                    Button("Novo canvas") { model.createDrawing(.canvas, in: model.active.map { BrainText.parent(of: $0.path) } ?? "") }
                } label: { Image(systemName: "scribble") }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .help("Novo desenho ou canvas")
                Button { model.prompt = .newFolder(folder: "") } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .help("Nova pasta")
                Button {
                    model.expanded = []
                    model.refreshTree()
                } label: { Image(systemName: "chevron.up.chevron.down") }
                    .buttonStyle(CircleButtonStyle(size: Theme.Control.compactHeight))
                    .help("Recolher tudo")
            }
            .padding(.leading, Theme.Space.s)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !model.bookmarks.paths.isEmpty {
                        SectionCaption(text: "Favoritos")
                        ForEach(model.bookmarks.paths, id: \.self) { path in
                            Button { model.open(path) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.busy)
                                    Text(BrainTree.displayName(path, isFolder: false)).font(Theme.Font.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                }
                            }
                            .buttonStyle(RowButtonStyle(highlight: model.active?.path == path ? .accent : .none, height: 24))
                        }
                        SectionCaption(text: "Pastas e notas")
                    }
                    ForEach(model.rows) { row in
                        BrainTreeRowView(row: row, model: model, isDropTarget: dropTarget == row.path)
                            .dropDestination(for: String.self) { items, _ in
                                guard row.isFolder, let source = items.first else { return false }
                                model.moveByDrop(source, into: row.path)
                                return true
                            } isTargeted: { targeted in
                                if row.isFolder { dropTarget = targeted ? row.path : (dropTarget == row.path ? nil : dropTarget) }
                            }
                    }
                    Color.clear.frame(height: 30)
                }
            }
            .scrollIndicators(.hidden)
            .dropDestination(for: String.self) { items, _ in
                guard let source = items.first else { return false }
                model.moveByDrop(source, into: "")
                return true
            }
        }
    }
}

private struct BrainTreeRowView: View {
    let row: BrainTreeRow
    var model: BrainModel
    let isDropTarget: Bool

    private var icon: String {
        if row.isFolder { return row.expanded ? "folder.fill" : "folder" }
        switch BrainFileKind.of(row.path) {
        case .note: return "doc.text"
        case .drawing: return "pencil.and.scribble"
        case .image: return "photo"
        case .other: return "doc"
        }
    }

    var body: some View {
        Button {
            if row.isFolder {
                model.toggleFolder(row.path)
            } else {
                model.open(row.path, newTab: NSEvent.modifierFlags.contains(.command))
            }
        } label: {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(row.depth) * 12, height: 1)
                if row.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(row.expanded ? 90 : 0))
                        .frame(width: 8)
                }
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(row.isFolder ? Theme.accent : Theme.textTertiary)
                    .frame(width: 14)
                Text(row.name)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if model.bookmarks.contains(row.path) {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.busy)
                }
            }
        }
        .buttonStyle(RowButtonStyle(highlight: isDropTarget ? .subtle : (model.active?.path == row.path ? .accent : .none), height: 24))
        .draggable(row.path)
        .contextMenu {
            if row.isFolder {
                Button("Nova nota aqui") { model.prompt = .newNote(folder: row.path) }
                Button("Novo desenho aqui") { model.createDrawing(.excalidraw, in: row.path) }
                Button("Novo canvas aqui") { model.createDrawing(.canvas, in: row.path) }
                Button("Nova subpasta") { model.prompt = .newFolder(folder: row.path) }
                Divider()
            } else {
                Button("Abrir em nova aba") { model.open(row.path, newTab: true) }
                Button(model.bookmarks.contains(row.path) ? "Remover dos favoritos" : "Favoritar") { model.toggleBookmark(row.path) }
                Button("Revelar no Finder") {
                    if let url = model.url(for: row.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
            }
            Button("Renomear ou mover…") { model.requestRename(row.path) }
            Button("Mover para o Lixo", role: .destructive) { model.prompt = .delete(path: row.path, isFolder: row.isFolder) }
        }
    }
}
