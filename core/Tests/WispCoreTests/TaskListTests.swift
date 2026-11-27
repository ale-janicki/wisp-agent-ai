import XCTest
@testable import WispCore

final class TaskListTests: XCTestCase {
    private let file = """
    ---
    aliases: [tarefas]
    - not an item
    ---

    # Tarefas

    Uma linha por tarefa. Resolveu: apague a linha.\u{20}\u{20}
    \tcom tab e espaço no fim\u{20}

    - **[Ana] Casa — trocar a lâmpada**. Próximo: comprar. Pronto quando: acende. [[casa|nota da casa]]
    - **[Bia] Carro — revisão**. Próximo: `ligar` pra oficina.

    ## Ana deve
    - **[Ana] Banco — pagar boleto**. Próximo: app.
    - Ana · linha solta sem o formato
    - **[Ana] Banco — pagar boleto**. Próximo: app.

    ## Vazio

    ## Bia decide
    - **[Bia] Viagem — escolher data**. Próximo: ver agenda. [[viagem]]
    """

    func testGroupsInFileOrderSkippingFrontmatterAndProse() {
        let groups = TaskList.parse(file)
        XCTAssertEqual(groups.map(\.title), [nil, "Ana deve", "Bia decide"])
        XCTAssertEqual(groups.map(\.items.count), [2, 3, 1])
        XCTAssertEqual(TaskList.openCount(groups), 6)
    }

    func testSplitsOwnerFrontTitleAndDetail() throws {
        let first = try XCTUnwrap(TaskList.parse(file).first?.items.first)
        XCTAssertEqual(first.owner, "Ana")
        XCTAssertEqual(first.front, "Casa")
        XCTAssertEqual(first.title, "trocar a lâmpada")
        XCTAssertEqual(first.detail, "Próximo: comprar. Pronto quando: acende. nota da casa")
        let loose = TaskList.parse(file)[1].items[1]
        XCTAssertNil(loose.owner)
        XCTAssertEqual(loose.title, "Ana · linha solta sem o formato")
        XCTAssertEqual(TaskList.parse(file)[0].items[1].detail, "Próximo: ligar pra oficina.")
    }

    func testDeletingRemovesOnlyThatLineByteForByte() throws {
        let groups = TaskList.parse(file)
        let target = groups[0].items[0]
        let updated = try TaskList.deleting(target, from: file)
        var expected = file.components(separatedBy: "\n")
        expected.removeAll { $0 == target.line }
        XCTAssertEqual(Data(updated.utf8), Data(expected.joined(separator: "\n").utf8))
        XCTAssertEqual(Data(file.utf8).count - Data(updated.utf8).count, Data((target.line + "\n").utf8).count)
    }

    func testDeletingTheSecondOfTwoIdenticalLines() throws {
        let duplicates = TaskList.parse(file)[1].items.filter { $0.title == "pagar boleto" }
        XCTAssertEqual(duplicates.map(\.occurrence), [0, 1])
        let updated = try TaskList.deleting(duplicates[1], from: file)
        let lines = updated.components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0 == duplicates[0].line }.count, 1)
        XCTAssertEqual(lines.firstIndex(of: duplicates[0].line), file.components(separatedBy: "\n").firstIndex(of: duplicates[0].line))
        XCTAssertTrue(updated.contains("- Ana · linha solta sem o formato\n- **[Bia]") == false)
        XCTAssertTrue(updated.contains("- Ana · linha solta sem o formato\n\n## Vazio"))
    }

    func testDeletingTheLastLineKeepsThePreviousNewline() throws {
        let text = "- a\n- b"
        let b = try XCTUnwrap(TaskList.parse(text).first?.items.last)
        XCTAssertEqual(try TaskList.deleting(b, from: text), "- a\n")
        let crlf = "- a\r\n- b\r\n"
        let a = try XCTUnwrap(TaskList.parse(crlf).first?.items.first)
        XCTAssertEqual(a.title, "a")
        XCTAssertEqual(try TaskList.deleting(a, from: crlf), "- b\r\n")
    }

    func testDeletingALineThatChangedThrows() throws {
        let target = try XCTUnwrap(TaskList.parse(file).first?.items.first)
        let edited = file.replacingOccurrences(of: "trocar a lâmpada", with: "trocar as lâmpadas")
        XCTAssertThrowsError(try TaskList.deleting(target, from: edited)) { error in
            XCTAssertEqual(error as? TaskListError, .lineChanged)
        }
    }

    func testCompleteWritesTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString).md")
        try Data(file.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let target = TaskList.parse(file)[2].items[0]
        try TaskList.complete(target, in: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, try TaskList.deleting(target, from: file))
        XCTAssertEqual(TaskList.parse(written).map(\.title), [nil, "Ana deve"])
    }

    func testFilterIsCaseAndAccentInsensitiveAndDropsEmptyGroups() {
        let groups = TaskList.filter(TaskList.parse(file), query: "LAMPADA casa")
        XCTAssertEqual(groups.map(\.title), [nil])
        XCTAssertEqual(groups.first?.items.map(\.title), ["trocar a lâmpada"])
        XCTAssertEqual(TaskList.filter(TaskList.parse(file), query: "  ").count, 3)
        XCTAssertEqual(TaskList.filter(TaskList.parse(file), query: "nada assim"), [])
    }

    func testLineIndexIsZeroBasedAndRespectsDuplicates() throws {
        let parts = file.components(separatedBy: "\n")
        let groups = TaskList.parse(file)
        let first = groups[0].items[0]
        XCTAssertEqual(TaskList.lineIndex(of: first, in: file), parts.firstIndex(of: first.line))
        let duplicates = groups[1].items.filter { $0.title == "pagar boleto" }
        let indexes = try duplicates.map { try XCTUnwrap(TaskList.lineIndex(of: $0, in: file)) }
        XCTAssertEqual(indexes.count, 2)
        XCTAssertLessThan(indexes[0], indexes[1])
        XCTAssertNil(TaskList.lineIndex(of: first, in: "outra coisa"))
    }

    func testPlain() {
        XCTAssertEqual(TaskList.plain("**a** `b` [[c]] [[d|e]] [[x"), "a b c e [[x")
    }

    private let alertText = """
    ---
    title: pendencias
    ---
    ## Agora
    - **[Ana] Wisp — Decidir isolamento**. Próximo: x. Pronto quando: y.
    - **[Ana] Acme — Rotacionar keys**. #urgente <!-- alerta:acme-keys tema:acme-keys -->
    - sem dono #urgente
    """

    func testUrgentFlagAndCommentStripped() throws {
        let items = try XCTUnwrap(TaskList.parse(alertText).first?.items)
        XCTAssertEqual(items.map(\.urgent), [false, true, true])
        XCTAssertEqual(items[1].owner, "Ana")
        XCTAssertEqual(items[1].front, "Acme")
        XCTAssertEqual(items[1].title, "Rotacionar keys")
        XCTAssertEqual(items[1].detail, "")
        XCTAssertEqual(items[2].title, "sem dono")
        XCTAssertFalse(items[1].line.isEmpty)
        XCTAssertTrue(items[1].line.contains("<!-- alerta:acme-keys"))
    }

    func testUrgentFirstKeepsOrderOtherwise() throws {
        let sorted = TaskList.urgentFirst(TaskList.parse(alertText))
        XCTAssertEqual(sorted[0].items.map(\.title), ["Rotacionar keys", "sem dono", "Decidir isolamento"])
    }

    func testCompleteUrgentRemovesExactRawLineAndKeepsFrontmatter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasks-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try alertText.write(to: url, atomically: true, encoding: .utf8)
        let target = try XCTUnwrap(TaskList.parse(alertText).first?.items[1])
        try TaskList.complete(target, in: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.contains("Rotacionar"))
        XCTAssertTrue(written.hasPrefix("---\ntitle: pendencias\n---\n## Agora\n"))
        XCTAssertEqual(TaskList.parse(written).first?.items.count, 2)
    }

    func testSearchIgnoresTheHiddenComment() {
        let groups = TaskList.parse(alertText)
        XCTAssertEqual(TaskList.filter(groups, query: "acme-keys"), [])
        XCTAssertEqual(TaskList.filter(groups, query: "rotacionar").first?.items.count, 1)
    }

    func testUrgenteOnlyCountsStandaloneInTheTail() {
        let text = """
        - **[Ana] X — #urgente no corpo**. nada
        - **[Ana] X — a**. #urgentes não
        - **[Ana] X — b**. Próximo: z #urgente
        - **[Ana] X — c**. <!-- #urgente -->
        - texto solto #urgente
        """
        let items = TaskList.parse(text).flatMap(\.items)
        XCTAssertEqual(items.map(\.urgent), [false, false, true, false, true])
        XCTAssertEqual(items[0].title, "#urgente no corpo")
        XCTAssertEqual(items[1].detail, "#urgentes não")
        XCTAssertEqual(items[2].detail, "Próximo: z")
    }

    func testFencedBlocksAreNotTasks() {
        let text = "- a\n```\n- x\n## h\n```\n- b\n~~~\n- y\n~~~\n- c"
        XCTAssertEqual(TaskList.parse(text).flatMap(\.items).map(\.title), ["a", "b", "c"])
    }

    func testFrontmatterToleratesTrailingSpaceAndUnterminatedIsNone() {
        let spaced = "--- \ntitle: x\n- nao\n---  \n- sim"
        XCTAssertEqual(TaskList.parse(spaced).flatMap(\.items).map(\.title), ["sim"])
        let open = "---\n- a\n- b"
        XCTAssertEqual(TaskList.parse(open).flatMap(\.items).map(\.title), ["a", "b"])
    }

    func testIdentityUsesAlertaChaveElseRawLine() {
        let one = TaskList.parse("- **[Ana] D — velho**. #urgente <!-- alerta:k1 tema:t -->").flatMap(\.items)[0]
        let two = TaskList.parse("- **[Ana] D — novo texto**. #urgente <!-- alerta:k1 tema:t -->").flatMap(\.items)[0]
        XCTAssertEqual(one.identity, two.identity)
        XCTAssertEqual(one.alertId, "k1")
        let manual = TaskList.parse("- manual #urgente").flatMap(\.items)[0]
        XCTAssertEqual(manual.identity, "- manual #urgente")
        XCTAssertEqual(Notices.newAlerts(old: [one], new: [two]), [])
    }

    func testCompleteWaitsForTheLockAndLeavesTheFileUntouchedWhenBusy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("sub/alerta.lock")
        let url = dir.appendingPathComponent("p.md")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try alertText.write(to: url, atomically: true, encoding: .utf8)
        let target = try XCTUnwrap(TaskList.parse(alertText).first?.items[0])

        let other = open(lock.path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0)
        let started = Date()
        XCTAssertThrowsError(try TaskList.complete(target, in: url, lock: lock, wait: 0.3)) { error in
            XCTAssertEqual(error as? TaskListError, .lockBusy)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), alertText)

        flock(other, LOCK_UN)
        close(other)
        try TaskList.complete(target, in: url, lock: lock, wait: 1)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("Decidir isolamento"))
    }
}
