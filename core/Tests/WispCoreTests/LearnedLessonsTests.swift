import XCTest
@testable import WispCore

final class LearnedLessonsTests: XCTestCase {
    private var brain: URL!
    private var lock: URL!

    override func setUpWithError() throws {
        brain = FileManager.default.temporaryDirectory.appendingPathComponent("lessons-\(UUID().uuidString)")
        lock = brain.appendingPathComponent("state/aprendizados.lock")
        try FileManager.default.createDirectory(at: brain.appendingPathComponent("wisp"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: brain)
    }

    private func write(_ text: String) throws {
        try text.write(to: LearnedLessons(brain: brain, lock: lock).url, atomically: true, encoding: .utf8)
    }

    func testParsesOnlyLessonLinesWithTheirParts() throws {
        try write("# O que o Wisp aprendeu\n\nTexto solto\n- Responda curto · 2026-11-19 · conversa: Viagem\n- Sem data\n-\n")
        let lessons = LearnedLessons(brain: brain, lock: lock).lessons()
        XCTAssertEqual(lessons.map(\.rule), ["Responda curto", "Sem data"])
        XCTAssertEqual(lessons[0].date, "2026-11-19")
        XCTAssertEqual(lessons[0].origin, "conversa: Viagem")
        XCTAssertNil(lessons[1].date)
    }

    func testMissingFileIsEmpty() {
        XCTAssertEqual(LearnedLessons(brain: brain, lock: lock).lessons(), [])
    }

    func testRemoveDeletesOnlyThatLineAndKeepsTheRest() throws {
        try write("# Título\n\n- A · 2026-01-01 · x\n- B · 2026-01-02 · y\n")
        let file = LearnedLessons(brain: brain, lock: lock)
        let first = try XCTUnwrap(file.lessons().first)
        XCTAssertTrue(try file.remove(first))
        XCTAssertEqual(file.lessons().map(\.rule), ["B"])
        XCTAssertTrue(try String(contentsOf: file.url, encoding: .utf8).hasPrefix("# Título\n"))
    }

    func testRemovingALineAlreadyGoneReturnsFalse() throws {
        try write("- A · 2026-01-01 · x\n")
        let file = LearnedLessons(brain: brain, lock: lock)
        let lesson = try XCTUnwrap(file.lessons().first)
        try write("- B · 2026-01-02 · y\n")
        XCTAssertFalse(try file.remove(lesson))
        XCTAssertEqual(file.lessons().map(\.rule), ["B"])
    }

    func testIdsAreUniqueEvenForIdenticalLines() throws {
        try write("- A · 2026-01-01 · x\n- A · 2026-01-01 · x\n")
        let ids = LearnedLessons(brain: brain, lock: lock).lessons().map(\.id)
        XCTAssertEqual(Set(ids).count, 2)
    }

    func testIndentedDashIsNotALessonLikePython() throws {
        try write("  - A · 2026-01-01 · x\n- B\n")
        XCTAssertEqual(LearnedLessons(brain: brain, lock: lock).lessons().map(\.rule), ["B"])
    }

    func testHarvestOriginIsMarkedAsLearnedAlone() throws {
        try write("- A · 2026-01-01 · colheita\n- B · 2026-01-01 · conversa: x\n")
        XCTAssertEqual(LearnedLessons(brain: brain, lock: lock).lessons().map(\.learnedAlone), [true, false])
    }

    func testRemoveCreatesTheSharedLockFile() throws {
        try write("- A · 2026-01-01 · x\n")
        let file = LearnedLessons(brain: brain, lock: lock)
        try file.remove(try XCTUnwrap(file.lessons().first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }
}
