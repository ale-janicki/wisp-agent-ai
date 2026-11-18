import XCTest
@testable import WispCore

final class LinkGraphTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-graph-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func miniVault() throws {
        try write("Alpha.md", """
        ---
        tags: [x]
        ---
        Veja [[beta]], [[Gamma|o gama]] e [[delta#Seção 2]].
        Embutido: ![[epsilon]] e ![[foto.png]] e ![[diagrama.svg|300]].
        Quebrado: [[nao-existe]] e [[Alpha]] (eu mesmo) e [[#só um título]].
        Duplicata: [[dup]] e caminho [[y/dup]].
        """)
        try write("pasta1/beta.md", "Volta pra [[ALPHA.md]] e de novo [[alpha]].\n```swift\nlet x = \"[[codigo]]\"\n```\nTexto `[[inline]]` e ~~~ não abre.\n")
        try write("pasta1/gamma.md", "| tabela | [[beta\\|apelido]] |\n")
        try write("pasta2/fundo/delta.md", "sem links")
        try write("epsilon.md", "[[pasta1/gamma]] [[../pasta1/beta]]")
        try write("x/dup.md", "")
        try write("x/y/dup.md", "")
        try write("orfa.md", "nada aqui")
        try write(".obsidian/escondida.md", "[[alpha]]")
        try write(".trash/lixo.md", "[[alpha]]")
        try write("foto.png", "png")
        try write("pasta1/.nota-na-nuvem.md.icloud", "placeholder")
    }

    func testExtractsTargetsSkippingAliasesHeadingsAndCode() {
        let text = """
        [[a]] [[b|alias]] [[c#h]] [[d#^bloco|x]] ![[e]] ![[f.png|200]] [[ g ]] [[#local]] [[t\\|apelido]]
        `[[inline]]` ``[[duplo `crase`]]`` [[depois]]
        ```
        [[cercado]]
        ```
        ~~~~
        [[til]]
        ~~~~
        [[aberto
        [[fim]]
        """
        XCTAssertEqual(WikiLinks.targets(in: text), ["a", "b", "c", "d", "e", "f.png", "g", "t", "depois", "fim"])
    }

    func testResolvesByBasenameCaseInsensitiveWithShortestPath() {
        let resolver = LinkResolver(paths: ["x/y/dup.md", "x/dup.md", "Alpha.md", "a/b/c/Nota.md", "Nota.md", "foo.excalidraw.md"])
        XCTAssertEqual(resolver.resolve("alpha", from: "z.md"), "Alpha.md")
        XCTAssertEqual(resolver.resolve("ALPHA.md", from: "z.md"), "Alpha.md")
        XCTAssertEqual(resolver.resolve("dup", from: "z.md"), "x/dup.md")
        XCTAssertEqual(resolver.resolve("nota", from: "a/b/c/z.md"), "Nota.md")
        XCTAssertEqual(resolver.resolve("y/dup", from: "z.md"), "x/y/dup.md")
        XCTAssertEqual(resolver.resolve("x/y/dup", from: "z.md"), "x/y/dup.md")
        XCTAssertEqual(resolver.resolve("../dup", from: "x/y/z.md"), "x/dup.md")
        XCTAssertEqual(resolver.resolve("foo.excalidraw", from: "z.md"), "foo.excalidraw.md")
        XCTAssertNil(resolver.resolve("foto.png", from: "z.md"))
        XCTAssertNil(resolver.resolve("nada", from: "z.md"))
        XCTAssertNil(LinkResolver.ghostName("foto.png"))
        XCTAssertEqual(LinkResolver.ghostName("pasta/Ideia Nova.md"), "Ideia Nova")
    }

    func testScansMiniVaultIntoNodesAndUndirectedEdges() throws {
        try miniVault()
        let scan = try LinkGraphScanner.scan(root: root.path)
        let graph = scan.graph
        XCTAssertEqual(graph.nodes.map(\.id), [
            "Alpha.md", "epsilon.md", "orfa.md", "pasta1/beta.md", "pasta1/gamma.md", "pasta2/fundo/delta.md", "x/dup.md", "x/y/dup.md",
        ])
        func id(_ index: Int) -> String { graph.nodes[index].id }
        let pairs = Set(graph.edges.map { [id($0.a), id($0.b)].sorted().joined(separator: " — ") })
        XCTAssertEqual(pairs, [
            "Alpha.md — pasta1/beta.md",
            "Alpha.md — pasta1/gamma.md",
            "Alpha.md — pasta2/fundo/delta.md",
            "Alpha.md — epsilon.md",
            "Alpha.md — x/dup.md",
            "Alpha.md — x/y/dup.md",
            "epsilon.md — pasta1/gamma.md",
            "epsilon.md — pasta1/beta.md",
            "pasta1/beta.md — pasta1/gamma.md",
        ])
        XCTAssertEqual(graph.edges.count, 9, "duplicate and reverse links collapse into one edge")
        let byId = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        XCTAssertEqual(byId["Alpha.md"]?.degree, 6)
        XCTAssertEqual(byId["orfa.md"]?.degree, 0)
        XCTAssertEqual(byId["pasta2/fundo/delta.md"]?.folder, "pasta2")
        XCTAssertEqual(byId["Alpha.md"]?.folder, "")
        XCTAssertEqual(byId["pasta1/beta.md"]?.title, "beta")
        XCTAssertFalse(graph.nodes.contains(where: \.isGhost), "ghosts are off by default")
        XCTAssertEqual(scan.stats.notes, 8)
        XCTAssertEqual(scan.stats.placeholders, 1)
    }

    func testGhostNodesForUnresolvedLinksWhenAsked() throws {
        try miniVault()
        let graph = try LinkGraphScanner.scan(root: root.path, includeGhosts: true).graph
        let ghosts = graph.nodes.filter(\.isGhost)
        XCTAssertEqual(ghosts.map(\.title), ["nao-existe"], "attachments never become ghosts")
        XCTAssertEqual(ghosts.first?.degree, 1)
        XCTAssertNil(ghosts.first?.path)
    }

    func testRescanReusesCacheAndOnlyReadsChangedFiles() throws {
        try miniVault()
        let first = try LinkGraphScanner.scan(root: root.path)
        XCTAssertEqual(first.stats.read, 8)

        let again = try LinkGraphScanner.scan(root: root.path, cache: first.cache)
        XCTAssertEqual(again.stats.read, 0)
        XCTAssertEqual(again.stats.reused, 8)
        XCTAssertEqual(again.graph, first.graph)

        try write("orfa.md", "agora liga [[beta]] e mais texto")
        try FileManager.default.removeItem(at: root.appendingPathComponent("x/y/dup.md"))
        let changed = try LinkGraphScanner.scan(root: root.path, cache: again.cache)
        XCTAssertEqual(changed.stats.read, 1)
        XCTAssertEqual(changed.stats.reused, 6)
        XCTAssertFalse(changed.graph.nodes.contains { $0.id == "x/y/dup.md" })
        XCTAssertEqual(changed.graph.nodes.first { $0.id == "orfa.md" }?.degree, 1)
    }

    func testCacheRoundTripsThroughDiskAndIgnoresOtherRoot() throws {
        try miniVault()
        let scan = try LinkGraphScanner.scan(root: root.path)
        let url = root.appendingPathComponent("cache/links.json")
        try scan.cache.save(to: url)
        let loaded = try XCTUnwrap(LinkScanCache.load(from: url))
        XCTAssertEqual(loaded, scan.cache)
        var foreign = loaded
        foreign.root = "/outro/lugar"
        XCTAssertEqual(try LinkGraphScanner.scan(root: root.path, cache: foreign).stats.read, 8)
    }

    func testUnreachableRootThrows() {
        XCTAssertThrowsError(try LinkGraphScanner.scan(root: root.appendingPathComponent("nao-tem").path)) { error in
            XCTAssertEqual(error as? LinkScanError, .unreachable(root.appendingPathComponent("nao-tem").path))
        }
    }

    func testNeighborhoodUpToDepth() throws {
        try miniVault()
        let graph = try LinkGraphScanner.scan(root: root.path).graph
        let adjacency = graph.adjacency()
        let delta = try XCTUnwrap(graph.nodes.firstIndex { $0.id == "pasta2/fundo/delta.md" })
        let one = Set(graph.neighborhood(of: delta, depth: 1, adjacency: adjacency).map { graph.nodes[$0].id })
        XCTAssertEqual(one, ["pasta2/fundo/delta.md", "Alpha.md"])
        let two = graph.neighborhood(of: delta, depth: 2, adjacency: adjacency)
        XCTAssertEqual(two.count, 7, "everything but the orphan is within two hops")
        XCTAssertEqual(graph.folders().first?.name, "", "root notes are the largest group here")
    }

    func testLiveVaultScanTimings() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WISP_LIVE"] == "1")
        let vault = "/tmp/brain"
        let clock = ContinuousClock()
        var cold: LinkScan?
        let coldTime = try clock.measure { cold = try LinkGraphScanner.scan(root: vault) }
        let first = try XCTUnwrap(cold)
        var warm: LinkScan?
        let warmTime = try clock.measure { warm = try LinkGraphScanner.scan(root: vault, cache: first.cache) }
        let second = try XCTUnwrap(warm)
        let ghosts = try LinkGraphScanner.scan(root: vault, cache: first.cache, includeGhosts: true).graph
        print("live graph: cold \(coldTime) warm \(warmTime) nodes=\(first.graph.nodes.count) edges=\(first.graph.edges.count) orphans=\(first.graph.nodes.filter { $0.degree == 0 }.count) ghosts=\(ghosts.nodes.filter(\.isGhost).count) placeholders=\(first.stats.placeholders) unreadable=\(first.stats.unreadable) warmRead=\(second.stats.read)")
        print("live graph: folders \(first.graph.folders().prefix(12).map { "\($0.name)=\($0.count)" })")
        XCTAssertEqual(second.graph, first.graph)

        var layout = GraphLayout(nodeCount: first.graph.nodes.count, edges: first.graph.edges)
        var steps = 0
        let layoutTime = clock.measure { while !layout.isSettled { layout.step(); steps += 1 } }
        print("live graph: layout \(steps) steps in \(layoutTime)")
        XCTAssertTrue(layout.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }
}
