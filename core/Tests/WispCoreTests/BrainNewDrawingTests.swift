import XCTest
@testable import WispCore

final class BrainNewDrawingTests: XCTestCase {
    private var root: URL!
    private let utc = TimeZone(identifier: "UTC")!
    private let moment = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-newdraw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testExcalidrawContentRoundTripsByteForByte() throws {
        let text = BrainNewDrawing.content(.excalidraw)
        XCTAssertTrue(text.contains("excalidraw-plugin: parsed"))
        XCTAssertTrue(text.contains("tags: [excalidraw]"))
        XCTAssertTrue(text.contains("# Excalidraw Data"))
        XCTAssertTrue(text.contains("## Text Elements"))
        XCTAssertTrue(text.contains("## Drawing"))
        let parsed = try ExcalidrawFile.parse(text, container: .markdown)
        XCTAssertEqual(parsed.serialized(), text)
        XCTAssertEqual(parsed.scene["elements"]?.arrayValue?.count, 0)
    }

    func testCanvasContentRoundTripsByteForByte() throws {
        let text = BrainNewDrawing.content(.canvas)
        let parsed = try JSONCanvas.parse(text)
        XCTAssertTrue(parsed.nodes.isEmpty)
        XCTAssertTrue(parsed.edges.isEmpty)
        XCTAssertEqual(parsed.serialized(), text)
    }

    func testNamesUseTheMinuteStampAndNeverOverwrite() throws {
        let files = BrainFiles(root: root.path)
        let first = try BrainNewDrawing.create(.excalidraw, in: "notas", files: files, now: moment, timeZone: utc)
        XCTAssertEqual(first, "notas/Desenho 2027-01-15 08.00.excalidraw.md")
        let second = try BrainNewDrawing.create(.excalidraw, in: "notas", files: files, now: moment, timeZone: utc)
        XCTAssertEqual(second, "notas/Desenho 2027-01-15 08.00 2.excalidraw.md")
        let third = try BrainNewDrawing.create(.excalidraw, in: "notas", files: files, now: moment, timeZone: utc)
        XCTAssertEqual(third, "notas/Desenho 2027-01-15 08.00 3.excalidraw.md")
        let canvas = try BrainNewDrawing.create(.canvas, in: "", files: files, now: moment, timeZone: utc)
        XCTAssertEqual(canvas, "Canvas 2027-01-15 08.00.canvas")
        let again = try BrainNewDrawing.create(.canvas, in: "", files: files, now: moment, timeZone: utc)
        XCTAssertEqual(again, "Canvas 2027-01-15 08.00 2.canvas")
        XCTAssertEqual(try files.read(canvas), BrainNewDrawing.content(.canvas))
    }

    func testAnExistingFileIsLeftUntouched() throws {
        let files = BrainFiles(root: root.path)
        try files.createNote("Canvas 2027-01-15 08.00.canvas", text: "mine")
        let made = try BrainNewDrawing.create(.canvas, in: "", files: files, now: moment, timeZone: utc)
        XCTAssertEqual(made, "Canvas 2027-01-15 08.00 2.canvas")
        XCTAssertEqual(try files.read("Canvas 2027-01-15 08.00.canvas"), "mine")
    }

    func testKnownTreePathsAreAvoidedCaseInsensitively() throws {
        let files = BrainFiles(root: root.path)
        let made = try BrainNewDrawing.create(.canvas, in: "", files: files, now: moment, timeZone: utc, knownPaths: ["canvas 2027-01-15 08.00.CANVAS"])
        XCTAssertEqual(made, "Canvas 2027-01-15 08.00 2.canvas")
    }

    func testBothKindsAreDrawingsForTheTree() {
        XCTAssertEqual(BrainFileKind.of("a/Desenho x.excalidraw.md"), .drawing)
        XCTAssertEqual(BrainFileKind.of("a/Canvas x.canvas"), .drawing)
    }
}
