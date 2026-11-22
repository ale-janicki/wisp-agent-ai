import XCTest
@testable import WispCore

final class DrawingSupportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-drawing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBridgeDecodesWhatTheWebPageSends() throws {
        func event(_ json: String) -> DrawingBridgeEvent? { DrawingBridgeEvent.decode(json) }
        XCTAssertEqual(event(#"{"type":"ready"}"#), .ready)
        XCTAssertEqual(event(#"{"type":"dirty"}"#), .dirty)
        XCTAssertEqual(event(#"{"type":"clean"}"#), .clean)
        XCTAssertEqual(event(#"{"type":"changed","scene":"{\"a\":1}"}"#), .changed(scene: "{\"a\":1}"))
        XCTAssertEqual(event(#"{"type":"save","scene":"{}"}"#), .save(scene: "{}"))
        XCTAssertEqual(event(#"{"type":"openLink","link":"[[nota]]"}"#), .openLink("[[nota]]"))
        XCTAssertEqual(event(#"{"type":"exported","format":"svg","data":"<svg/>"}"#), .exported(format: .svg, data: Data("<svg/>".utf8)))
        XCTAssertEqual(event(#"{"type":"exported","format":"png","data":"AQID"}"#), .exported(format: .png, data: Data([1, 2, 3])))
        XCTAssertEqual(event(#"{"type":"failure","message":"boom"}"#), .failure("boom"))
        XCTAssertNil(event(#"{"type":"exported","format":"png","data":"@@"}"#))
        XCTAssertNil(event(#"{"type":"unknown"}"#))
        XCTAssertNil(event("not json"))
        XCTAssertNil(DrawingBridgeEvent.decode(42))
    }

    func testBridgeCommandsEncodeAsASingleSafeScriptCall() throws {
        let scene = "{\"text\":\"linha\\nseparada \u{2028} \\\"aspas\\\"\"}"
        let command = DrawingBridgeCommand.load(scene: scene, files: .object([]), viewMode: true, dark: false, language: "pt-BR")
        let script = command.script
        XCTAssertTrue(script.hasPrefix("window.wispBridge.receive({"))
        XCTAssertTrue(script.hasSuffix("})"))
        XCTAssertFalse(script.contains("\u{2028}"))
        XCTAssertFalse(script.contains("\n"))
        let payload = String(script.dropFirst("window.wispBridge.receive(".count).dropLast())
        let decoded = try JSONValue.parse(payload)
        XCTAssertEqual(decoded["type"]?.stringValue, "load")
        XCTAssertEqual(decoded["scene"]?.stringValue, scene)
        XCTAssertEqual(decoded["viewMode"]?.boolValue, true)
        XCTAssertEqual(decoded["language"]?.stringValue, "pt-BR")
        XCTAssertEqual(DrawingBridgeCommand.setTheme(dark: true).script, #"window.wispBridge.receive({"type":"setTheme","dark":true})"#)
        XCTAssertEqual(DrawingBridgeCommand.export(.png).script, #"window.wispBridge.receive({"type":"export","format":"png"})"#)
        XCTAssertEqual(DrawingBridgeCommand.requestSave.script, #"window.wispBridge.receive({"type":"requestSave"})"#)
    }

    func testPageServerStaysInsideItsFolder() {
        let base = URL(fileURLWithPath: "/app/Excalidraw", isDirectory: true)
        XCTAssertEqual(DrawingContentSecurity.resolve(urlPath: "/", inside: base)?.path, "/app/Excalidraw/index.html")
        XCTAssertEqual(DrawingContentSecurity.resolve(urlPath: "/fonts/a%20b.woff2", inside: base)?.path, "/app/Excalidraw/fonts/a b.woff2")
        XCTAssertNil(DrawingContentSecurity.resolve(urlPath: "/../secret", inside: base))
        XCTAssertNil(DrawingContentSecurity.resolve(urlPath: "/fonts/%2e%2e/x", inside: base))
        XCTAssertEqual(DrawingContentSecurity.resolve(urlPath: "//etc/passwd", inside: base)?.path, "/app/Excalidraw/etc/passwd")
    }

    func testPolicyAllowsNoRemoteOrigin() {
        XCTAssertFalse(DrawingContentSecurity.policy.contains("http"))
        XCTAssertFalse(DrawingContentSecurity.policy.contains("*"))
        XCTAssertTrue(DrawingContentSecurity.policy.hasPrefix("default-src 'none'"))
        XCTAssertEqual(DrawingContentSecurity.mimeType(forPath: "a/b.woff2"), "font/woff2")
    }

    func testLinksParse() {
        XCTAssertEqual(DrawingLink.parse("[[nota]]"), .note(target: "nota", heading: nil))
        XCTAssertEqual(DrawingLink.parse("[[pasta/nota#Seção|apelido]]"), .note(target: "pasta/nota", heading: "Seção"))
        XCTAssertEqual(DrawingLink.parse("![[nota]]"), .note(target: "nota", heading: nil))
        XCTAssertEqual(DrawingLink.parse("[[#só título]]")?.noteReference, "#só título")
        XCTAssertEqual(DrawingLink.parse("https://example.com/a"), .url(URL(string: "https://example.com/a")!))
        XCTAssertNil(DrawingLink.parse("javascript:alert(1)"))
        XCTAssertNil(DrawingLink.parse("  "))
        XCTAssertEqual(DrawingLink.wikilinks(in: "veja [[a]] e [[b|c]]\n[[d]]").compactMap(\.noteReference), ["a", "b", "d"])
    }

    func testFileStateDecidesWhatToDoWithExternalChanges() {
        var state = DrawingFileState()
        let v1 = Data("um".utf8), v2 = Data("dois".utf8)
        state.didLoad(v1)
        XCTAssertEqual(state.externalChange(diskData: v1), .none)
        XCTAssertEqual(state.externalChange(diskData: v2), .reload)
        state.dirty = true
        XCTAssertEqual(state.externalChange(diskData: v2), .prompt)
        XCTAssertEqual(state.externalChange(diskData: v1), .none)
        state.didWrite(v2)
        XCTAssertFalse(state.dirty)
        XCTAssertEqual(state.externalChange(diskData: v2), .none)
    }

    func testNewDrawingFollowsThePluginSettings() throws {
        let plugin = root.appendingPathComponent(ExcalidrawPluginSettings.pluginFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data(#"{"folder":"Desenhos","drawingFilenamePrefix":"Rascunho ","drawingFilenameDateTime":"YYYY-MM-DD HH.mm.ss","useExcalidrawExtension":true,"compress":false}"#.utf8).write(to: plugin.appendingPathComponent("data.json"))
        try Data(#"{"version":"9.9.9"}"#.utf8).write(to: plugin.appendingPathComponent("manifest.json"))

        let settings = ExcalidrawPluginSettings.load(brain: root)
        XCTAssertEqual(settings.folder, "Desenhos")
        XCTAssertEqual(settings.pluginVersion, "9.9.9")
        XCTAssertFalse(settings.compress)

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(settings.fileName(at: date, timeZone: utc), "Rascunho 2027-01-15 08.00.00.excalidraw.md")

        let first = try NewDrawing.create(brain: root, settings: settings, now: date, timeZone: utc)
        let second = try NewDrawing.create(brain: root, settings: settings, now: date, timeZone: utc)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "Desenhos")
        XCTAssertEqual(second.lastPathComponent, "Rascunho 2027-01-15 08.00.00_0.excalidraw.md")
        let loaded = try ExcalidrawFile.load(from: first)
        XCTAssertEqual(loaded.encoding, .json)
        XCTAssertTrue(loaded.scene["source"]?.stringValue?.hasSuffix("/9.9.9") == true)
    }

    func testNewDrawingDefaultsWithoutThePlugin() throws {
        let url = try NewDrawing.create(brain: root, now: Date(timeIntervalSince1970: 0), timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Excalidraw")
        XCTAssertEqual(url.lastPathComponent, "Drawing 1970-01-01 00.00.00.excalidraw.md")
        XCTAssertEqual(try ExcalidrawFile.load(from: url).encoding, .compressed)
    }

    func testDateFormatSupportsLiteralsInBrackets() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(ExcalidrawPluginSettings.format(Date(timeIntervalSince1970: 0), pattern: "[Dia] DD-MM-YY", timeZone: utc), "Dia 01-01-70")
    }

    func testSVGRenderDrawsTheLiveElements() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/drawings/neutral-compressed", withExtension: "excalidraw.md"))
        let file = try ExcalidrawFile.load(from: url)
        let svg = try XCTUnwrap(ExcalidrawSVG.render(scene: file.scene))
        XCTAssertTrue(svg.hasPrefix("<svg xmlns="))
        XCTAssertTrue(svg.contains("<rect "))
        XCTAssertTrue(svg.contains("Caixa um"))
        XCTAssertTrue(svg.contains("segunda linha"))
        XCTAssertTrue(svg.contains("<ellipse") == false)
        XCTAssertNil(ExcalidrawSVG.render(scene: ExcalidrawFile.blank().scene))
    }

    func testEmbedCacheIsKeyedByContent() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/drawings/neutral-compressed", withExtension: "excalidraw.md"))
        let copy = root.appendingPathComponent("a.excalidraw.md")
        let other = root.appendingPathComponent("b.excalidraw.md")
        try FileManager.default.copyItem(at: source, to: copy)
        try FileManager.default.copyItem(at: source, to: other)
        let disk = root.appendingPathComponent("cache", isDirectory: true)
        let cache = DrawingEmbedCache(folder: disk)
        let first = try await cache.svg(for: copy)
        let second = try await cache.svg(for: other)
        XCTAssertEqual(first, second)
        let count = await cache.cachedCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: disk.path).count, 1)

        var edited = try ExcalidrawFile.load(from: copy)
        var scene = edited.scene
        scene["elements"] = .array([])
        try edited.apply(sceneJSON: scene.serialized()) { _ in "" }
        try edited.write(to: copy)
        let blank = try await cache.svg(for: copy)
        XCTAssertNil(blank)
        let after = await cache.cachedCount
        XCTAssertEqual(after, 2)

        let revived = DrawingEmbedCache(folder: disk)
        let fromDisk = try await revived.svg(for: other)
        XCTAssertEqual(fromDisk, first)
    }

    func testAttachmentsResolveNextToTheDrawingThenByNameInTheVault() async throws {
        let drawing = root.appendingPathComponent("desenhos/a.excalidraw.md")
        try FileManager.default.createDirectory(at: drawing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("anexos/fundo"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("desenhos/perto.png"))
        try Data([2]).write(to: root.appendingPathComponent("anexos/fundo/longe.png"))
        XCTAssertEqual(DrawingAttachments.resolve(target: "perto.png", near: drawing, vaultRoot: root)?.lastPathComponent, "perto.png")
        XCTAssertNil(DrawingAttachments.resolve(target: "longe.png", near: drawing, vaultRoot: root))
        XCTAssertEqual(DrawingAttachments.resolve(target: "anexos/fundo/longe.png", near: drawing, vaultRoot: root)?.lastPathComponent, "longe.png")
        let index = DrawingNameIndex()
        let found = await DrawingAttachments.resolve(target: "longe.png", near: drawing, vaultRoot: root, index: index)
        XCTAssertEqual(found?.pathComponents.suffix(3), ["anexos", "fundo", "longe.png"])
        let missing = await DrawingAttachments.resolve(target: "nao-existe.png", near: drawing, vaultRoot: root, index: index)
        XCTAssertNil(missing)
        let noRoot = await DrawingAttachments.resolve(target: "longe.png", near: drawing, vaultRoot: nil, index: index)
        XCTAssertNil(noRoot)
    }

    func testAttachmentsNeverEscapeTheBrainRoot() async throws {
        let vault = root.appendingPathComponent("brain", isDirectory: true)
        let outside = root.appendingPathComponent("fora", isDirectory: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("notas"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([9]).write(to: outside.appendingPathComponent("segredo.png"))
        try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("notas/atalho.png"), withDestinationURL: outside.appendingPathComponent("segredo.png"))
        try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("pasta-fora"), withDestinationURL: outside)
        let drawing = vault.appendingPathComponent("notas/a.excalidraw.md")
        XCTAssertNil(DrawingAttachments.resolve(target: "../../fora/segredo.png", near: drawing, vaultRoot: vault))
        XCTAssertNil(DrawingAttachments.resolve(target: "atalho.png", near: drawing, vaultRoot: vault))
        XCTAssertNil(DrawingAttachments.resolve(target: "pasta-fora/segredo.png", near: drawing, vaultRoot: vault))
        XCTAssertNil(DrawingAttachments.resolve(target: "/etc/hosts", near: drawing, vaultRoot: vault))
        let viaIndex = await DrawingAttachments.resolve(target: "segredo.png", near: drawing, vaultRoot: vault, index: DrawingNameIndex())
        XCTAssertNil(viaIndex)
        XCTAssertNil(DrawingAttachments.confined(outside.appendingPathComponent("segredo.png"), to: vault))
        XCTAssertNotNil(DrawingAttachments.confined(vault.appendingPathComponent("notas"), to: vault))
    }

    func testRecoveryCopyNamesKeepTheDrawingExtension() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let drawing = root.appendingPathComponent("Meu desenho.excalidraw.md")
        let first = DrawingRecovery.recoveryURL(for: drawing, now: date, timeZone: utc)
        XCTAssertEqual(first.lastPathComponent, "Meu desenho (conflito Wisp 2027-01-15 08.00.00).excalidraw.md")
        try Data().write(to: first)
        XCTAssertEqual(DrawingRecovery.recoveryURL(for: drawing, now: date, timeZone: utc).lastPathComponent, "Meu desenho (conflito Wisp 2027-01-15 08.00.00)_0.excalidraw.md")
        XCTAssertEqual(DrawingRecovery.recoveryURL(for: root.appendingPathComponent("a.canvas"), now: date, timeZone: utc).lastPathComponent, "a (conflito Wisp 2027-01-15 08.00.00).canvas")
        XCTAssertEqual(DrawingRecovery.recoveryURL(for: root.appendingPathComponent("a.excalidraw"), now: date, timeZone: utc).lastPathComponent, "a (conflito Wisp 2027-01-15 08.00.00).excalidraw")
    }

    func testSVGSkipsElementsWithHugeOrNonFiniteNumbers() throws {
        func rect(_ id: String, x: JSONValue) -> JSONValue {
            .object([
                JSONMember(key: "id", value: .string(id)), JSONMember(key: "type", value: .string("rectangle")),
                JSONMember(key: "x", value: x), JSONMember(key: "y", value: .int(0)),
                JSONMember(key: "width", value: .int(50)), JSONMember(key: "height", value: .int(20)),
            ])
        }
        let scene = JSONValue.object([JSONMember(key: "elements", value: .array([
            rect("ok", x: .int(10)), rect("inf", x: .number("1e999")), rect("huge", x: .number("1e30")),
        ]))])
        let svg = try XCTUnwrap(ExcalidrawSVG.render(scene: scene))
        XCTAssertEqual(svg.components(separatedBy: "<rect x=\"10\"").count - 1, 1)
        XCTAssertFalse(svg.contains("inf"))
        XCTAssertFalse(svg.contains("nan"))
        XCTAssertFalse(svg.contains("e+"))
        let onlyBad = JSONValue.object([JSONMember(key: "elements", value: .array([rect("inf", x: .number("1e999")), rect("huge", x: .number("1e30"))]))])
        XCTAssertNil(ExcalidrawSVG.render(scene: onlyBad))
    }

    func testPastedImagesGetUniqueNames() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let first = DrawingAttachments.uniqueURL(forPastedImage: "image/png", in: root, now: Date(timeIntervalSince1970: 0), timeZone: utc)
        XCTAssertEqual(first.lastPathComponent, "Pasted Image 19700101000000_000.png")
        try Data().write(to: first)
        let second = DrawingAttachments.uniqueURL(forPastedImage: "image/png", in: root, now: Date(timeIntervalSince1970: 0), timeZone: utc)
        XCTAssertEqual(second.lastPathComponent, "Pasted Image 19700101000000_000_0.png")
    }
}
