import AppKit
import Foundation
import Observation
import WispCore

@MainActor @Observable
final class MemoryModel {
    static let shared = MemoryModel()

    enum Recents: Equatable {
        case loading
        case loaded([MemoryNote])
    }

    enum Search: Equatable {
        case idle
        case searching(String)
        case loaded(query: String, hits: [MemoryHit])
        case failed(String)
    }

    private(set) var recents: Recents = .loading
    private(set) var search: Search = .idle

    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var recentsGeneration = 0

    static let debounce: Duration = .milliseconds(250)

    func refreshRecents(root: String) {
        recentsGeneration += 1
        let current = recentsGeneration
        Task { [weak self] in
            let notes = await Task.detached(priority: .userInitiated) { MemorySearch.recentNotes(root: root) }.value
            guard let self, self.recentsGeneration == current else { return }
            self.recents = .loaded(notes)
        }
    }

    func search(_ query: String, block: MemoryBlock) async {
        searchGeneration += 1
        let current = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            search = .idle
            return
        }
        guard let template = block.search, let rawRoot = block.root else { return }
        if case .loaded(let previous, _) = search, previous == trimmed { return }
        search = .searching(trimmed)
        try? await Task.sleep(for: Self.debounce)
        guard searchGeneration == current, !Task.isCancelled else { return }

        let root = MemorySearch.resolvedRoot(rawRoot)
        guard let command = MemorySearch.command(template: template, query: trimmed, root: root) else { return }
        let result = await Task.detached(priority: .userInitiated) { BlockCommand.run(command) }.value
        guard searchGeneration == current else { return }
        switch result {
        case .success(let data):
            search = .loaded(query: trimmed, hits: MemorySearch.ranked(MemorySearch.parse(data, root: root), query: trimmed))
        case .failure(let error):
            search = .failed("Não consegui buscar nas notas: \(error.localizedDescription)")
        }
    }
}
