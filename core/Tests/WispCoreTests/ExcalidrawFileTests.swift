import XCTest
@testable import WispCore

final class ExcalidrawFileTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/drawings/\(name)", withExtension: ext))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testReadsTheCompressedPluginFormat() throws {
        let file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        XCTAssertEqual(file.encoding, .compressed)
        XCTAssertEqual(file.scene["type"]?.stringValue, "excalidraw")
        XCTAssertEqual(file.elements.count, 6)
        XCTAssertTrue(file.header.hasPrefix("---\n\nexcalidraw-plugin: parsed"))
        XCTAssertTrue(file.header.hasSuffix("Texto livre antes dos dados, preservado.\n\n"))
        XCTAssertTrue(file.trailer.contains("## Mudanças"))
    }

    func testCompressedAndPlainJSONHoldTheSameScene() throws {
        let compressed = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        let plain = try ExcalidrawFile.parse(fixture("neutral-json", "excalidraw.md"), container: .markdown)
        XCTAssertEqual(plain.encoding, .json)
        XCTAssertEqual(compressed.scene, plain.scene)
    }

    func testUnchangedFilesComeBackByteForByte() throws {
        for name in ["neutral-compressed", "neutral-json"] {
            let original = try fixture(name, "excalidraw.md")
            let file = try ExcalidrawFile.parse(original, container: .markdown)
            XCTAssertEqual(file.serialized(), original, name)
        }
    }

    func testTextElementsKeepTheRawTextAndSkipDeletedOnes() throws {
        let file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        XCTAssertEqual(file.textElements.map(\.id), ["EeFfGgH2", "IiJjKkL3"])
        XCTAssertEqual(file.textElements[1].raw, "Veja [[nota-exemplo]]\nsegunda linha")
        XCTAssertTrue(file.serialized().contains("Veja [[nota-exemplo]]\nsegunda linha ^IiJjKkL3\n\n"))
    }

    func testTextElementsSectionIsRegeneratedFromTheScene() throws {
        var file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        var scene = file.scene
        var elements = try XCTUnwrap(scene["elements"]?.arrayValue)
        elements[1]["text"] = .string("Caixa editada")
        elements[1]["originalText"] = .string("Caixa editada")
        elements[1]["rawText"] = .string("Caixa editada")
        elements.append(.object([
            JSONMember(key: "id", value: .string("NewText1")),
            JSONMember(key: "type", value: .string("text")),
            JSONMember(key: "text", value: .string("Novo")),
            JSONMember(key: "originalText", value: .string("Novo")),
        ]))
        elements.remove(at: 2)
        scene["elements"] = .array(elements)
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }

        let text = file.serialized()
        XCTAssertTrue(text.contains("## Text Elements\nCaixa editada ^EeFfGgH2\n\nNovo ^NewText1\n\n"))
        XCTAssertFalse(text.contains("IiJjKkL3"))
        let reread = try ExcalidrawFile.parse(text, container: .markdown)
        XCTAssertEqual(reread.textElements.map(\.id), ["EeFfGgH2", "NewText1"])
    }

    func testUnknownSectionsAndEmbeddedFilesSurviveASave() throws {
        var file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        XCTAssertEqual(file.embeddedFiles.map(\.id), ["f00dcafe", "latex01"])
        var scene = file.scene
        scene["appState"]?["viewBackgroundColor"] = .string("#fafafa")
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }
        let text = file.serialized()
        XCTAssertTrue(text.contains("Texto livre antes dos dados, preservado."))
        XCTAssertTrue(text.contains("f00dcafe: [[pixel.png]]\n\n"))
        XCTAssertTrue(text.hasSuffix("\n\n## Mudanças\n- 2026-01-01 00:00 · Desenho de exemplo\n"))
        XCTAssertTrue(text.contains("```compressed-json\n"))
        let reread = try ExcalidrawFile.parse(text, container: .markdown)
        XCTAssertEqual(reread.scene["appState"]?["viewBackgroundColor"]?.stringValue, "#fafafa")
    }

    func testLatexEntryKeepsItsDollarBlock() throws {
        let file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        XCTAssertEqual(file.embeddedFiles.last?.text, "latex01: $$\\frac{a}{b}$$")
    }

    func testCompressedBodyIsSplitInFixedWidthLines() throws {
        let text = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown).serialized()
        let block = try XCTUnwrap(text.components(separatedBy: "```compressed-json\n").last?.components(separatedBy: "\n```").first)
        let chunks = block.components(separatedBy: "\n\n")
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.count == 256 })
        XCTAssertLessThanOrEqual(chunks.last?.count ?? 0, 256)
    }

    func testPlainExcalidrawJSONRoundTrips() throws {
        let original = try fixture("neutral", "excalidraw")
        let file = try ExcalidrawFile.parse(original, container: .plainJSON)
        XCTAssertEqual(file.container, .plainJSON)
        XCTAssertEqual(file.indent, "  ")
        XCTAssertEqual(file.serialized(), original)
    }

    func testNewImagesBecomeAttachmentsAndEmbeddedEntries() throws {
        var file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        var scene = file.scene
        var elements = try XCTUnwrap(scene["elements"]?.arrayValue)
        elements.append(.object([
            JSONMember(key: "id", value: .string("ImgEl001")),
            JSONMember(key: "type", value: .string("image")),
            JSONMember(key: "fileId", value: .string("newfile1")),
        ]))
        scene["elements"] = .array(elements)
        scene["files"] = .object([
            JSONMember(key: "newfile1", value: .object([
                JSONMember(key: "mimeType", value: .string("image/png")),
                JSONMember(key: "dataURL", value: .string("data:image/png;base64,AQID")),
            ])),
        ])
        var stored: [ExcalidrawFile.NewAttachment] = []
        let created = try file.apply(sceneJSON: scene.serialized()) { attachment in
            stored.append(attachment)
            return "Pasted Image 1.png"
        }
        XCTAssertEqual(created, stored)
        XCTAssertEqual(stored.first?.data, Data([1, 2, 3]))
        let text = file.serialized()
        XCTAssertTrue(text.contains("newfile1: [[Pasted Image 1.png]]\n\n"))
        XCTAssertEqual(file.scene["files"], .object([]))
        XCTAssertFalse(text.contains("AQID"))
    }

    func testAnEmbeddedEntryStaysWhileTheDrawingIsOpenAndIsPrunedOnClose() throws {
        var file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        var scene = file.scene
        scene["elements"] = .array((scene["elements"]?.arrayValue ?? []).filter { $0["type"]?.stringValue != "image" })
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }
        XCTAssertEqual(file.embeddedFiles.map(\.id), ["f00dcafe", "latex01"])
        XCTAssertEqual(file.unreferencedEmbeddedIDs, ["f00dcafe", "latex01"])
        XCTAssertTrue(file.serialized().contains("f00dcafe: [[pixel.png]]"))
        XCTAssertTrue(file.pruneEmbeddedFiles())
        XCTAssertTrue(file.embeddedFiles.isEmpty)
        XCTAssertFalse(file.serialized().contains("## Embedded Files"))
        XCTAssertFalse(file.pruneEmbeddedFiles())
    }

    func testUndoingAnImageDeletionReusesTheEntryAndWritesNoDuplicate() throws {
        var file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        let original = file.scene
        var without = original
        without["elements"] = .array((original["elements"]?.arrayValue ?? []).filter { $0["type"]?.stringValue != "image" })
        var withImage = original
        withImage["files"] = .object([JSONMember(key: "f00dcafe", value: .object([
            JSONMember(key: "mimeType", value: .string("image/png")),
            JSONMember(key: "dataURL", value: .string("data:image/png;base64,AQID")),
        ]))])
        var stored = 0
        try file.apply(sceneJSON: without.serialized()) { _ in stored += 1; return "x.png" }
        try file.apply(sceneJSON: withImage.serialized()) { _ in stored += 1; return "x.png" }
        XCTAssertEqual(stored, 0)
        XCTAssertEqual(file.embeddedFiles.filter { $0.id == "f00dcafe" }.count, 1)
        XCTAssertFalse(file.serialized().contains("Pasted Image"))
        XCTAssertTrue(file.unreferencedEmbeddedIDs == ["latex01"])
    }

    func testPlainFilesKeepTheirTrailingNewlineState() throws {
        let withNewline = try fixture("neutral", "excalidraw")
        let without = String(withNewline.dropLast())
        XCTAssertEqual(try ExcalidrawFile.parse(without, container: .plainJSON).serialized(), without)
        XCTAssertEqual(try ExcalidrawFile.parse(withNewline, container: .plainJSON).serialized(), withNewline)
    }

    func testNewElementsGetEightCharacterIdsThePluginCanParse() throws {
        var file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        var scene = file.scene
        var elements = try XCTUnwrap(scene["elements"]?.arrayValue)
        let longID = "abcdefghijklmnopqrstu"
        elements.append(.object([
            JSONMember(key: "id", value: .string(longID)),
            JSONMember(key: "type", value: .string("text")),
            JSONMember(key: "text", value: .string("Novo texto")),
            JSONMember(key: "originalText", value: .string("Novo texto")),
            JSONMember(key: "link", value: .string("[[outra-nota]]")),
            JSONMember(key: "boundElements", value: .array([])),
        ]))
        elements.append(.object([
            JSONMember(key: "id", value: .string("arrow-with-long-id-0001")),
            JSONMember(key: "type", value: .string("arrow")),
            JSONMember(key: "startBinding", value: .object([JSONMember(key: "elementId", value: .string(longID))])),
            JSONMember(key: "link", value: .string("https://example.com")),
        ]))
        scene["elements"] = .array(elements)
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }

        let ids = file.elements.compactMap { $0["id"]?.stringValue }
        XCTAssertTrue(ids.suffix(2).allSatisfy { $0.count == 8 })
        XCTAssertFalse(ids.contains(longID))
        let binding = file.elements.last?["startBinding"]?["elementId"]?.stringValue
        XCTAssertEqual(binding, ids[ids.count - 2])

        let text = file.serialized()
        let anchors = try NSRegularExpression(pattern: "\\s\\^(.{8})[\\n]+")
        let links = try NSRegularExpression(pattern: "^(.{8}):\\s*(.*)$", options: .anchorsMatchLines)
        let range = NSRange(text.startIndex..., in: text)
        let anchored = anchors.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        let linked = links.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        XCTAssertTrue(anchored.contains(ids[ids.count - 2]))
        XCTAssertEqual(anchored.count, file.textElements.count)
        XCTAssertTrue(linked.contains(ids[ids.count - 2]))
        XCTAssertTrue(linked.contains(ids[ids.count - 1]))
        XCTAssertTrue(linked.contains("AaBbCcD1"))
    }

    func testEditedTextKeepsItsWikilinkMarkup() throws {
        var file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        var scene = file.scene
        var elements = try XCTUnwrap(scene["elements"]?.arrayValue)
        elements[2]["text"] = .string("Olha só nota-exemplo\nsegunda linha")
        elements[2]["originalText"] = .string("Olha só nota-exemplo\nsegunda linha")
        elements[2]["rawText"] = .string("")
        scene["elements"] = .array(elements)
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }
        XCTAssertTrue(file.serialized().contains("Olha só [[nota-exemplo]]\nsegunda linha ^IiJjKkL3\n\n"))
        XCTAssertTrue(file.notices.isEmpty)
    }

    func testEditedTextThatLostTheLinkFallsBackAndSaysSo() throws {
        var file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        var scene = file.scene
        var elements = try XCTUnwrap(scene["elements"]?.arrayValue)
        elements[2]["text"] = .string("Texto sem o destino")
        elements[2]["originalText"] = .string("Texto sem o destino")
        scene["elements"] = .array(elements)
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }
        XCTAssertTrue(file.serialized().contains("Texto sem o destino ^IiJjKkL3"))
        XCTAssertEqual(file.notices.count, 1)
        XCTAssertTrue(file.notices[0].contains("[[nota-exemplo]]"))
    }

    func testAStalePlaceholderRawTextNeverWinsOverEditedText() throws {
        var file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        var scene = file.scene
        var elements = try XCTUnwrap(scene["elements"]?.arrayValue)
        elements[1]["text"] = .string("Caixa nova")
        elements[1]["originalText"] = .string("Caixa nova")
        elements[1]["rawText"] = .string("Caixa um")
        scene["elements"] = .array(elements)
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }
        XCTAssertTrue(file.serialized().contains("Caixa nova ^EeFfGgH2"))
        XCTAssertFalse(file.serialized().contains("Caixa um ^"))
    }

    func testFilesPayloadResolvesEmbeddedImagesAndSkipsTheRest() throws {
        let file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        let png = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/drawings/pixel", withExtension: "png"))
        let payload = file.filesPayload { $0 == "pixel.png" ? png : nil }
        let entry = try XCTUnwrap(payload["f00dcafe"])
        XCTAssertEqual(entry["mimeType"]?.stringValue, "image/png")
        XCTAssertTrue(entry["dataURL"]?.stringValue?.hasPrefix("data:image/png;base64,iVBOR") == true)
        XCTAssertNil(payload["latex01"])
    }

    func testElementLinksAreWrittenForLinkedElements() throws {
        let file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        XCTAssertTrue(file.serialized().contains("## Element Links\nAaBbCcD1: [[nota-exemplo]]\n\n"))
    }

    func testRejectsFilesWithoutADrawingSection() {
        XCTAssertThrowsError(try ExcalidrawFile.parse("# só uma nota\n", container: .markdown)) {
            XCTAssertEqual($0 as? ExcalidrawFile.ParseError, .noDrawingSection)
        }
        let broken = "# Excalidraw Data\n\n## Text Elements\n%%\n## Drawing\n```compressed-json\n!!!!\n```\n%%"
        XCTAssertThrowsError(try ExcalidrawFile.parse(broken, container: .markdown))
    }

    func testBlankDrawingIsReadableByTheParserAndHasThePluginHeader() throws {
        let blank = ExcalidrawFile.blank()
        let text = blank.serialized()
        XCTAssertTrue(text.hasPrefix("---\n\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n\n---\n==⚠"))
        XCTAssertTrue(text.contains("# Excalidraw Data\n\n## Text Elements\n%%\n## Drawing\n```compressed-json\n"))
        let reread = try ExcalidrawFile.parse(text, container: .markdown)
        XCTAssertEqual(reread.scene["type"]?.stringValue, "excalidraw")
        XCTAssertEqual(reread.elements.count, 0)
    }

    func testContainerFollowsTheFileName() {
        XCTAssertEqual(ExcalidrawFile.container(forFileNamed: "x.excalidraw.md"), .markdown)
        XCTAssertEqual(ExcalidrawFile.container(forFileNamed: "x.EXCALIDRAW"), .plainJSON)
        XCTAssertNil(ExcalidrawFile.container(forFileNamed: "x.md"))
    }

    func testWriteIsAtomicAndReadable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-excalidraw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.excalidraw.md")
        try ExcalidrawFile.blank().write(to: url)
        try ExcalidrawFile.blank(compressed: false).write(to: url)
        XCTAssertEqual(try ExcalidrawFile.load(from: url).encoding, .json)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["a.excalidraw.md"])
    }

    func testAppStateKeysTheEditorDoesNotSendAreKept() throws {
        var file = try ExcalidrawFile.parse(fixture("neutral-compressed", "excalidraw.md"), container: .markdown)
        var scene = file.scene
        scene["appState"] = .object([JSONMember(key: "viewBackgroundColor", value: .string("#000000")), JSONMember(key: "gridModeEnabled", value: .bool(false))])
        let previous = file.scene["appState"]?.objectMembers?.map(\.key) ?? []
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }
        let keys = file.scene["appState"]?.objectMembers?.map(\.key) ?? []
        XCTAssertEqual(keys, previous + ["gridModeEnabled"])
        XCTAssertEqual(file.scene["appState"]?["viewBackgroundColor"]?.stringValue, "#000000")
    }
}
