import SwiftUI
import WispCore

struct BrainHomeView: View {
    let block: MemoryBlock?
    var openNote: (String) -> Void
    var openDaily: () -> Void
    @State private var query = Self.initialQuery
    private let memory = MemoryModel.shared

    #if DEBUG
    static var snapshotQuery = ""
    #endif

    private static var initialQuery: String {
        #if DEBUG
        return snapshotQuery
        #else
        return ""
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                if block?.search != nil {
                    SearchField(text: $query, placeholder: "Buscar nas notas")
                } else {
                    Spacer(minLength: 0)
                }
                Button("Nota de hoje", action: openDaily).buttonStyle(CapsuleButtonStyle(kind: .accent, size: .compact))
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recents
            } else {
                results
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .task(id: query) {
            if let block { await memory.search(query, block: block) }
        }
    }

    @ViewBuilder
    private var recents: some View {
        switch memory.recents {
        case .loading:
            SkeletonRows(count: 6)
        case .loaded(let notes) where notes.isEmpty:
            TabMessage(text: "Nenhuma nota nesta pasta")
        case .loaded(let notes):
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SectionCaption(text: "Recentes")
                    ForEach(notes) { note in
                        NoteRow(title: note.title, folder: MemoryNote.folder(of: note.path), age: AlertList.age(of: note.modifiedAt)) {
                            openNote(note.path)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var results: some View {
        switch memory.search {
        case .idle, .searching:
            SkeletonRows(count: 5)
        case .loaded(let searched, let hits) where hits.isEmpty:
            TabMessage(text: "Nenhuma nota com “\(searched)”")
        case .loaded(_, let hits):
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SectionCaption(text: Self.count(hits.count))
                    ForEach(hits) { hit in
                        NoteRow(title: hit.title, folder: MemoryNote.folder(of: hit.path), snippet: hit.text) {
                            openNote(hit.path)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        case .failed(let message):
            TabMessage(text: message)
        }
    }

    private static func count(_ n: Int) -> String {
        if n >= MemorySearch.resultLimit { return "As primeiras \(n) notas" }
        return n == 1 ? "1 nota" : "\(n) notas"
    }
}

private struct NoteRow: View {
    let title: String
    let folder: String
    var snippet: String?
    var age: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(title)
                            .font(Theme.Font.bodyMedium)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if snippet != nil, !folder.isEmpty {
                            Text(folder)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .layoutPriority(-1)
                        }
                    }
                    Text(snippet ?? (folder.isEmpty ? "raiz" : folder))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(snippet == nil ? .head : .tail)
                }
                Spacer(minLength: Theme.Space.s)
                if let age {
                    Text(age)
                        .font(Theme.Font.captionMono)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(RowButtonStyle(height: 44))
        .help(snippet ?? title)
    }
}
