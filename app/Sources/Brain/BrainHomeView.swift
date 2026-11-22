import SwiftUI
import WispCore

struct BrainHomeView: View {
    var model: BrainModel
    var openNote: (String) -> Void
    var openDaily: () -> Void
    private let memory = MemoryModel.shared

    #if DEBUG
    static var snapshotQuery = ""
    #endif

    private var query: String { model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                Button("Nota de hoje", action: openDaily).buttonStyle(CapsuleButtonStyle(kind: .accent, size: .compact))
            }
            if query.isEmpty {
                recents
            } else {
                results
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .onAppear { model.search(model.searchQuery) }
        .onChange(of: model.searchQuery) { model.search(model.searchQuery) }
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
        if let message = model.searchError {
            TabMessage(text: message)
        } else if model.searching {
            SkeletonRows(count: 5)
        } else if model.searchHits.isEmpty {
            TabMessage(text: "Nenhuma nota com “\(query)”")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SectionCaption(text: Self.count(model.searchHits.count))
                    ForEach(model.searchHits) { hit in
                        NoteRow(title: hit.title, folder: BrainText.parent(of: hit.path), snippet: hit.snippet) {
                            openNote(hit.path)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private static func count(_ n: Int) -> String {
        n == 1 ? "1 nota" : "\(n) notas"
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
