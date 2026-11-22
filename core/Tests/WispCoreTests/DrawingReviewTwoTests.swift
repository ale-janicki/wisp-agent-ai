import XCTest
@testable import WispCore

final class DrawingReviewTwoTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-review2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var brain: URL { root.appendingPathComponent("brain", isDirectory: true) }

    private func makeBrain() throws {
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
    }

    private func settings(folder: String = "Excalidraw", prefix: String = "Drawing ", format: String = "YYYY-MM-DD HH.mm.ss") -> ExcalidrawPluginSettings {
        var value = ExcalidrawPluginSettings()
        value.folder = folder
        value.filenamePrefix = prefix
        value.dateFormat = format
        return value
    }

    func testNewDrawingRefusesFoldersThatLeaveTheBrain() throws {
        try makeBrain()
        for folder in ["../../../Library/LaunchAgents", "/Library/LaunchAgents", "Excalidraw/../../fora", "~/x", "..\\fora"] {
            XCTAssertThrowsError(try NewDrawing.create(brain: brain, settings: settings(folder: folder)), folder) {
                guard case NewDrawing.Failure.unsafeFolder = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fora").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: brain.path), [])
    }

    func testNewDrawingStripsSeparatorsFromNamesAndDates() throws {
        try makeBrain()
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let url = try NewDrawing.create(brain: brain, settings: settings(prefix: "../../evil/", format: "YYYY/MM:DD"), now: Date(timeIntervalSince1970: 0), timeZone: utc)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Excalidraw")
        XCTAssertEqual(url.lastPathComponent, "....evil19700101.excalidraw.md")
        XCTAssertNotNil(DrawingAttachments.confined(url, to: brain))
    }

    func testNewDrawingRefusesAFolderThatIsASymlinkOutOfTheBrain() throws {
        try makeBrain()
        let outside = root.appendingPathComponent("fora", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: brain.appendingPathComponent("Excalidraw"), withDestinationURL: outside)
        XCTAssertThrowsError(try NewDrawing.create(brain: brain, settings: settings())) {
            XCTAssertEqual($0 as? NewDrawing.Failure, .outsideBrain)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testNewCanvasStaysInsideTheBrain() throws {
        try makeBrain()
        let inside = try NewDrawing.createCanvas(in: brain.appendingPathComponent("notas"), brain: brain, named: "../x/Mapa")
        XCTAssertEqual(inside.lastPathComponent, "..xMapa.canvas")
        XCTAssertThrowsError(try NewDrawing.createCanvas(in: root.appendingPathComponent("fora"), brain: brain))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fora").path))
    }

    func testLeavingEditModeFlushesTheLastStrokeAndAcceptsItsLateEvents() {
        var session = DrawingEditSession()
        XCTAssertEqual(session.setEditing(true, pageReady: true), [.setViewMode(false)])
        XCTAssertEqual(session.handle(.dirty), [])
        XCTAssertTrue(session.pageDirty)
        XCTAssertEqual(session.setEditing(false, pageReady: true), [.requestSave, .setViewMode(true)])
        XCTAssertEqual(session.handle(.changed(scene: "{\"late\":1}")), [.scheduleAutosave])
        XCTAssertEqual(session.pendingScene, "{\"late\":1}")
        XCTAssertEqual(session.handle(.save(scene: "{\"final\":1}")), [.cancelAutosave, .writeNow])
        XCTAssertEqual(session.pendingScene, "{\"final\":1}")
        session.didWrite()
        XCTAssertFalse(session.hasUnsavedWork)
        XCTAssertEqual(session.handle(.changed(scene: "{\"stale\":1}")), [])
        XCTAssertNil(session.pendingScene)
    }

    func testLeavingEditModeWithNothingPendingDoesNotWrite() {
        var session = DrawingEditSession()
        _ = session.setEditing(true, pageReady: true)
        XCTAssertEqual(session.setEditing(false, pageReady: true), [.setViewMode(true)])
        XCTAssertEqual(session.handle(.save(scene: "{}")), [])
    }

    func testACleanReplyEndsTheWaitForASave() {
        var session = DrawingEditSession()
        _ = session.setEditing(true, pageReady: true)
        _ = session.handle(.dirty)
        _ = session.setEditing(false, pageReady: true)
        XCTAssertTrue(session.awaitingSave)
        _ = session.handle(.clean)
        XCTAssertFalse(session.awaitingSave)
        XCTAssertFalse(session.pageDirty)
    }

    func testOnlyWebLinksAndMailOpenFromDrawings() {
        XCTAssertNil(DrawingLink.parse("obsidian://open?vault=x&file=y"))
        XCTAssertNotNil(DrawingLink.parse("https://example.com"))
        XCTAssertNotNil(DrawingLink.parse("mailto:a@example.com"))
    }

    func testAtomicWriteFollowsAnInBrainSymlinkAndKeepsMode() throws {
        try makeBrain()
        let real = brain.appendingPathComponent("real.excalidraw.md")
        try Data("old".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
        let link = brain.appendingPathComponent("link.excalidraw.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try AtomicFile.write(Data("new".utf8), to: link, root: brain, expectingHash: DrawingFileState.hash(of: Data("old".utf8)))
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        let mode = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o640)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: brain.path).sorted(), ["link.excalidraw.md", "real.excalidraw.md"])
    }

    func testAtomicWriteRefusesASymlinkOutOfTheBrain() throws {
        try makeBrain()
        let outside = root.appendingPathComponent("fora.txt")
        try Data("keep".utf8).write(to: outside)
        let link = brain.appendingPathComponent("a.excalidraw.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try AtomicFile.write(Data("x".utf8), to: link, root: brain)) {
            XCTAssertEqual($0 as? AtomicFile.Failure, .outsideRoot)
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }

    func testAtomicWriteRefusesWhenTheDiskChangedSinceTheHash() throws {
        try makeBrain()
        let file = brain.appendingPathComponent("a.canvas")
        try Data("one".utf8).write(to: file)
        let known = DrawingFileState.hash(of: Data("one".utf8))
        try Data("two".utf8).write(to: file)
        XCTAssertThrowsError(try AtomicFile.write(Data("mine".utf8), to: file, root: brain, expectingHash: known)) {
            XCTAssertEqual($0 as? AtomicFile.Failure, .changedOnDisk)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: brain.path), ["a.canvas"])
        try AtomicFile.write(Data("mine".utf8), to: file, root: brain)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mine")
    }

    func testLoneSurrogateInJSONOpensReadOnly() throws {
        let json = "{\"type\":\"excalidraw\",\"version\":2,\"elements\":[{\"id\":\"a\",\"type\":\"text\",\"text\":\"x\\ud800y\"}],\"appState\":{},\"files\":{}}"
        let plain = try ExcalidrawFile.parse(json, container: .plainJSON)
        XCTAssertEqual(plain.readOnlyNotice, ExcalidrawFile.lossyNotice)
        let target = root.appendingPathComponent("a.excalidraw")
        XCTAssertThrowsError(try plain.write(to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let clean = try ExcalidrawFile.parse(json.replacingOccurrences(of: "\\ud800", with: "z"), container: .plainJSON)
        XCTAssertNil(clean.readOnlyNotice)
    }

    func testInvalidUTF8OpensReadOnly() throws {
        var bytes = Data("{\"type\":\"excalidraw\",\"version\":2,\"elements\":[],\"appState\":{},\"files\":{},\"note\":\"".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append(Data("\"}".utf8))
        let file = try ExcalidrawFile.parse(data: bytes, container: .plainJSON)
        XCTAssertEqual(file.readOnlyNotice, ExcalidrawFile.lossyNotice)
        let canvas = try JSONCanvas.parse(data: Data("{\"nodes\":[{\"id\":\"a\",\"type\":\"text\",\"text\":\"".utf8) + Data([0xC3]) + Data("\",\"x\":0,\"y\":0,\"width\":1,\"height\":1}]}".utf8))
        XCTAssertEqual(canvas.readOnlyNotice, JSONCanvas.lossyNotice)
        XCTAssertThrowsError(try canvas.write(to: root.appendingPathComponent("a.canvas")))
        XCTAssertNil(try JSONCanvas.parse("{\"nodes\":[]}").readOnlyNotice)
    }

    func testLoneSurrogateInsideCompressedDataOpensReadOnly() throws {
        let scene = "{\"type\":\"excalidraw\",\"version\":2,\"elements\":[{\"id\":\"a\",\"type\":\"text\",\"text\":\"k"
        var units = Array(scene.utf16)
        units.append(0xD800)
        units.append(contentsOf: Array("\"}],\"appState\":{},\"files\":{}}".utf16))
        let packed = LZString.compressToBase64(units: units)
        let text = "# Excalidraw Data\n\n## Text Elements\n%%\n## Drawing\n```compressed-json\n\(packed)\n```\n%%"
        let file = try ExcalidrawFile.parse(text, container: .markdown)
        XCTAssertEqual(file.readOnlyNotice, ExcalidrawFile.lossyNotice)
    }

    private let unknownSample = """
    ---
    excalidraw-plugin: parsed
    ---
    # Excalidraw Data

    Linha solta do usuário antes dos textos

    ## Text Elements
    Hello ^AAAA1111

    ## Notas do usuário
    texto livre
    com duas linhas

    ## Element Links
    linha perdida nos links

    AAAA1111: [[nota]]

    ## Embedded Files
    ff00: [[a.png]]

    comentário entre arquivos

    ff01: [[b.png]]

    sobra no fim dos arquivos

    %%
    ## Drawing
    ```json
    {"type":"excalidraw","version":2,"elements":[{"id":"AAAA1111","type":"text","text":"Hello","originalText":"Hello"},{"id":"IMG00001","type":"image","fileId":"ff00"},{"id":"IMG00002","type":"image","fileId":"ff01"}],"appState":{},"files":{}}
    ```
    %%
    """

    func testUnknownLinesAndSectionsInTheDataRegionSurviveInPlace() throws {
        let file = try ExcalidrawFile.parse(unknownSample, container: .markdown)
        let marker = "%%\n## Drawing\n"
        let written = file.serialized()
        XCTAssertEqual(written.components(separatedBy: marker)[0], unknownSample.components(separatedBy: marker)[0])
        XCTAssertEqual(try ExcalidrawFile.parse(written, container: .markdown).serialized(), written)
        XCTAssertNil(file.readOnlyNotice)
    }

    func testUnknownLinesSurviveASaveAndAPrune() throws {
        var file = try ExcalidrawFile.parse(unknownSample, container: .markdown)
        var scene = file.scene
        scene["elements"] = .array((scene["elements"]?.arrayValue ?? []).filter { $0["id"]?.stringValue != "IMG00002" })
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }
        XCTAssertTrue(file.pruneEmbeddedFiles() == true)
        let text = file.serialized()
        for kept in ["Linha solta do usuário antes dos textos", "## Notas do usuário\ntexto livre\ncom duas linhas", "linha perdida nos links", "comentário entre arquivos", "sobra no fim dos arquivos", "ff00: [[a.png]]"] {
            XCTAssertTrue(text.contains(kept), kept)
        }
        XCTAssertFalse(text.contains("ff01"))
        let reread = try ExcalidrawFile.parse(text, container: .markdown)
        XCTAssertEqual(reread.embeddedFiles.map(\.id), ["ff00"])
        XCTAssertTrue(text.range(of: "Hello ^AAAA1111")!.lowerBound < text.range(of: "## Notas do usuário")!.lowerBound)
        XCTAssertTrue(text.range(of: "## Notas do usuário")!.lowerBound < text.range(of: "## Element Links")!.lowerBound)
    }
}
