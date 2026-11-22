import XCTest
@testable import WispCore

final class MemorySearchTests: XCTestCase {
    private let root = "/vault/notes"

    func testFillsTemplateWithQuotedValues() {
        let command = MemorySearch.command(
            template: "grep -rIin --null -m 1 -F -e {query} {root}/ | head -n 200",
            query: "  it's here ",
            root: "/a b/vault"
        )
        XCTAssertEqual(command, #"grep -rIin --null -m 1 -F -e 'it'\''s here' '/a b/vault'/ | head -n 200"#)
        XCTAssertNil(MemorySearch.command(template: "x {query}", query: "  \n", root: root))
    }

    func testParsesNullSeparatedOutputOneHitPerNote() {
        let output = Data("""
        /vault/notes/projetos/alpha.md\u{0}12:  - [ ] revisar o alpha\t
        /vault/notes/projetos/alpha.md\u{0}30:segunda linha do mesmo arquivo
        /vault/notes/diario: 2026.md\u{0}4:linha com: dois pontos
        /outra/pasta/fora.md\u{0}1:fora da raiz
        lixo sem separador

        """.utf8)
        let hits = MemorySearch.parse(output, root: root)
        XCTAssertEqual(hits, [
            MemoryHit(path: "projetos/alpha.md", line: 12, text: "- [ ] revisar o alpha"),
            MemoryHit(path: "diario: 2026.md", line: 4, text: "linha com: dois pontos"),
        ])
        XCTAssertEqual(hits.first?.title, "alpha")
        XCTAssertEqual(MemoryNote.folder(of: "projetos/alpha.md"), "projetos")
        XCTAssertEqual(MemoryNote.folder(of: "raiz.md"), "")
    }

    func testParsesColonSeparatedOutputAndRelativePaths() {
        let output = Data("""
        ./a/b.md:7:texto: com 3:dois pontos
        c.md:1:outro
        /vault/notes/d.md:2:abs
        """.utf8)
        let hits = MemorySearch.parse(output, root: root + "/")
        XCTAssertEqual(hits.map(\.path), ["a/b.md", "c.md", "d.md"])
        XCTAssertEqual(hits.first?.line, 7)
        XCTAssertEqual(hits.first?.text, "texto: com 3:dois pontos")
    }

    func testParseHonoursLimitAndTruncatesLongLines() {
        let long = String(repeating: "x", count: 1_000)
        let lines = (0..<80).map { "/vault/notes/n\($0).md\u{0}1:\(long)" }.joined(separator: "\n")
        let hits = MemorySearch.parse(Data(lines.utf8), root: root, limit: 50)
        XCTAssertEqual(hits.count, 50)
        XCTAssertEqual(hits[0].text.count, MemorySearch.maxLineLength)
    }

    func testRanksTitleMatchesFirstKeepingOrder() {
        let hits = [
            MemoryHit(path: "a/um.md", line: 1, text: "sync"),
            MemoryHit(path: "b/brain-sync.md", line: 1, text: "x"),
            MemoryHit(path: "c/dois.md", line: 1, text: "sync"),
            MemoryHit(path: "d/Sync notes.md", line: 1, text: "x"),
        ]
        XCTAssertEqual(MemorySearch.ranked(hits, query: " SYNC ").map(\.path), ["b/brain-sync.md", "d/Sync notes.md", "a/um.md", "c/dois.md"])
    }

    func testObsidianURLEncodesVaultAndPath() {
        let url = MemorySearch.obsidianURL(root: "/x/meu vault", path: "pasta/nota ação & co.md")
        XCTAssertEqual(url?.absoluteString, "obsidian://open?vault=meu%20vault&file=pasta%2Fnota%20a%C3%A7%C3%A3o%20%26%20co.md")
    }

    func testRecentNotesNewestFirstSkippingHiddenAndNonMarkdown() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let files = ["velha.md", "sub/nova.md", "sub/meio.md", "imagem.png", ".obsidian/workspace.md", ".oculta.md"]
        for (index, name) in files.enumerated() {
            let url = dir.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60)], ofItemAtPath: url.path)
        }
        let link = fm.temporaryDirectory.appendingPathComponent("memory-link-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? fm.removeItem(at: link) }

        let notes = MemorySearch.recentNotes(root: link.path, limit: 2)
        XCTAssertEqual(notes.map(\.path), ["sub/meio.md", "sub/nova.md"])
        XCTAssertEqual(MemorySearch.recentNotes(root: link.path).map(\.path), ["sub/meio.md", "sub/nova.md", "velha.md"])
        XCTAssertFalse(MemorySearch.resolvedRoot(link.path + "/").hasSuffix("/"))
    }

    func testSearchCommandRunsAgainstSymlinkedRootWithSystemGrep() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("memory-grep-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("linha um\nPalavra Chave aqui\n".utf8).write(to: dir.appendingPathComponent("a/nota.md"))
        try Data("palavra chave".utf8).write(to: dir.appendingPathComponent(".git/oculta.md"))
        try Data("palavra chave".utf8).write(to: dir.appendingPathComponent("a/outra.txt"))
        let link = fm.temporaryDirectory.appendingPathComponent("memory-grep-link-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? fm.removeItem(at: link) }

        let root = MemorySearch.resolvedRoot(link.path)
        let template = "/usr/bin/grep -rIin --null --include='*.md' --exclude-dir='.*' -m 1 -F -e {query} {root} | head -n 200"
        let command = try XCTUnwrap(MemorySearch.command(template: template, query: "palavra chave", root: root))
        let data = try BlockCommand.run(command, path: "/usr/bin:/bin").get()
        XCTAssertEqual(MemorySearch.parse(data, root: root), [MemoryHit(path: "a/nota.md", line: 2, text: "Palavra Chave aqui")])

        let none = try XCTUnwrap(MemorySearch.command(template: template, query: "não existe", root: root))
        XCTAssertEqual(try BlockCommand.run(none, path: "/usr/bin:/bin").get(), Data())
    }

    func testRelativePathOnlyInsideTheRoot() {
        XCTAssertEqual(MemorySearch.relativePath(ofFile: "/tmp/wisp-root/a/tarefas.md", inRoot: "/tmp/wisp-root/"), "a/tarefas.md")
        XCTAssertNil(MemorySearch.relativePath(ofFile: "/tmp/wisp-root-other/tarefas.md", inRoot: "/tmp/wisp-root"))
        XCTAssertNil(MemorySearch.relativePath(ofFile: "/tmp/wisp-root", inRoot: "/tmp/wisp-root"))
    }
}
