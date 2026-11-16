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

    func testPlain() {
        XCTAssertEqual(TaskList.plain("**a** `b` [[c]] [[d|e]] [[x"), "a b c e [[x")
    }
}
