import XCTest
@testable import WispCore

final class MessageAttachmentsTests: XCTestCase {
    private let phoneUpload = """
        [o Ale enviou 3 arquivo(s) pelo Telegram, ja salvos nesta maquina:
        - /Users/x/.wisp-telegram/anexos/2026-11-17/6125-foto-6125.jpg (foto-6125.jpg, 99013 bytes)
        - /Users/x/.wisp-telegram/anexos/2026-11-17/6126-relatorio (1).pdf (relatorio (1).pdf, 2048 bytes)
        - foto: nao consegui baixar (File is too big)]

        (sem texto — veja o que é e me diga)
        """

    func testParsesThePhoneBlockAndDropsThePlaceholderCaption() throws {
        let parsed = try XCTUnwrap(MessageAttachments.parse(phoneUpload))
        XCTAssertEqual(parsed.origin, "Telegram")
        XCTAssertNil(parsed.caption)
        XCTAssertEqual(parsed.items, [
            .file(path: "/Users/x/.wisp-telegram/anexos/2026-11-17/6125-foto-6125.jpg", name: "foto-6125.jpg", bytes: 99013),
            .file(path: "/Users/x/.wisp-telegram/anexos/2026-11-17/6126-relatorio (1).pdf", name: "relatorio (1).pdf", bytes: 2048),
            .failed(label: "foto"),
        ])
    }

    func testKeepsAMultilineCaption() throws {
        let text = "[o Ale enviou 1 arquivo(s) pelo Wisp, ja salvos nesta maquina:\n- /a/b.png (b.png, 3 bytes)]\n\nolha\nisso"
        let parsed = try XCTUnwrap(MessageAttachments.parse(text))
        XCTAssertEqual(parsed.origin, "Wisp")
        XCTAssertEqual(parsed.caption, "olha\nisso")
        XCTAssertEqual(parsed.items, [.file(path: "/a/b.png", name: "b.png", bytes: 3)])
    }

    func testPlainTextAndBrokenBlocksAreNotAttachments() {
        XCTAssertNil(MessageAttachments.parse("oi"))
        XCTAssertNil(MessageAttachments.parse("[o Ale enviou 2 arquivo(s) pelo Telegram, ja salvos nesta maquina:\n- /a.jpg (a.jpg, 1 bytes)]\n\noi"))
        XCTAssertNil(MessageAttachments.parse("[o Ale enviou 1 arquivo(s) pelo Telegram, ja salvos nesta maquina:\n- /a.jpg (a.jpg, 1 bytes)"))
    }

    func testComposeMatchesTheBotByteForByteAndRoundTrips() throws {
        let files = [StagedAttachment(path: "/h/.wisp-telegram/anexos/2026-11-17/wisp-a1-praia.jpg", name: "wisp-a1-praia.jpg", bytes: 4)]
        let empty = MessageAttachments.compose(origin: "Wisp", files: files, caption: "  ")
        XCTAssertEqual(empty, "[o usuario enviou 1 arquivo(s) pelo Wisp, ja salvos nesta maquina:\n"
            + "- /h/.wisp-telegram/anexos/2026-11-17/wisp-a1-praia.jpg (wisp-a1-praia.jpg, 4 bytes)]\n\n"
            + "(sem texto — veja o que é e me diga)")
        XCTAssertNil(try XCTUnwrap(MessageAttachments.parse(empty)).caption)
        XCTAssertTrue(MessageAttachments.compose(origin: "Wisp", files: files, caption: "", user: "Rita").hasPrefix("[o Rita enviou "))
        XCTAssertTrue(MessageAttachments.compose(origin: "Wisp", files: files, caption: "", user: " ").hasPrefix("[o usuario enviou "))
        XCTAssertEqual(try XCTUnwrap(MessageAttachments.parse(MessageAttachments.compose(origin: "Wisp", files: files, caption: "", user: "Rita"))).items.count, 1)
        let captioned = MessageAttachments.compose(origin: "Wisp", files: files, caption: " olha ")
        XCTAssertEqual(try XCTUnwrap(MessageAttachments.parse(captioned)).caption, "olha")
    }

    func testImageKindByExtension() {
        for name in ["a.jpg", "b.JPEG", "c.png", "d.heic", "e.gif", "f.webp"] { XCTAssertTrue(MessageAttachments.isImage(name), name) }
        for name in ["a.pdf", "b", "c.mp4", "jpg"] { XCTAssertFalse(MessageAttachments.isImage(name), name) }
    }

    func testStagingCopiesIntoTodaysFolderUnderUniqueNames() throws {
        let tmp = try scratch()
        let source = tmp.appendingPathComponent("src/praia.jpg")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("jpg!".utf8).write(to: source)
        let root = tmp.appendingPathComponent("anexos", isDirectory: true)
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour) = (2026, 11, 17, 12)
        let day = try XCTUnwrap(Calendar.current.date(from: parts))

        let staged = try AttachmentStaging.stage([source, source], into: root, on: day)
        XCTAssertEqual(staged.count, 2)
        guard staged.count == 2 else { return }
        XCTAssertNotEqual(staged[0].path, staged[1].path)
        for item in staged {
            XCTAssertTrue(item.path.hasPrefix(root.appendingPathComponent("2026-11-17").path + "/"), item.path)
            XCTAssertTrue(item.name.hasPrefix("wisp-") && item.name.hasSuffix("-praia.jpg"), item.name)
            XCTAssertEqual(item.bytes, 4)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: item.path)), Data("jpg!".utf8))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testSummaryForOneLinePreviews() throws {
        XCTAssertEqual(try XCTUnwrap(MessageAttachments.parse(phoneUpload)).summary, "1 foto · 2 arquivos")
        let one = "[o Ale enviou 2 arquivo(s) pelo Wisp, ja salvos nesta maquina:\n- /a.jpg (a.jpg, 1 bytes)\n- /b.png (b.png, 1 bytes)]\n\nolha"
        XCTAssertEqual(try XCTUnwrap(MessageAttachments.parse(one)).summary, "2 fotos · olha")
    }

    func testDisplayNameDropsTheWispPrefix() {
        XCTAssertEqual(MessageAttachments.displayName("wisp-1a2b3c4d-nota.pdf"), "nota.pdf")
        XCTAssertEqual(MessageAttachments.displayName("wisp-nota.pdf"), "wisp-nota.pdf")
        XCTAssertEqual(MessageAttachments.displayName("foto-6125.jpg"), "foto-6125.jpg")
    }

    // MARK: Fix round 1

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return URL(fileURLWithPath: try XCTUnwrap(realpath(url.path, nil).map { String(cString: $0) }), isDirectory: true)
    }

    func testOnlyRegularFilesAreAttachedAndLinksResolveToTheirTarget() throws {
        let tmp = try scratch()
        let fm = FileManager.default
        let photo = tmp.appendingPathComponent("praia.jpg")
        try Data("x".utf8).write(to: photo)
        let link = tmp.appendingPathComponent("atalho.jpg")
        try fm.createSymbolicLink(at: link, withDestinationURL: photo)
        let folder = tmp.appendingPathComponent("pasta", isDirectory: true)
        let app = tmp.appendingPathComponent("Coisa.app", isDirectory: true)
        let library = tmp.appendingPathComponent("Fotos.photoslibrary", isDirectory: true)
        for dir in [folder, app, library] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let folderLink = tmp.appendingPathComponent("atalho-pasta")
        try fm.createSymbolicLink(at: folderLink, withDestinationURL: folder)

        let checked = AttachmentStaging.regularFiles([photo, link, folder, app, library, folderLink])
        XCTAssertEqual(checked.files.map(\.path), [photo.path, photo.path])
        XCTAssertEqual(checked.refused, ["pasta", "Coisa.app", "Fotos.photoslibrary", "atalho-pasta"])
        XCTAssertEqual(AttachmentStaging.refusal(["pasta", "Coisa.app"]),
                       "Não anexei pasta, Coisa.app: só dá para anexar arquivos, não pastas nem pacotes.")
    }

    func testStagingCopiesTheTargetOfALinkNeverTheLink() throws {
        let tmp = try scratch()
        let photo = tmp.appendingPathComponent("praia.jpg")
        try Data("jpg!".utf8).write(to: photo)
        let link = tmp.appendingPathComponent("atalho.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: photo)
        let staged = try AttachmentStaging.stage([link], into: tmp.appendingPathComponent("anexos"))
        let type = try FileManager.default.attributesOfItem(atPath: staged[0].path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
        XCTAssertEqual(staged[0].bytes, 4)
    }

    func testStagingThatFailsPartwayLeavesNoCopies() throws {
        let tmp = try scratch()
        let photo = tmp.appendingPathComponent("praia.jpg")
        try Data("jpg!".utf8).write(to: photo)
        let root = tmp.appendingPathComponent("anexos", isDirectory: true)
        XCTAssertThrowsError(try AttachmentStaging.stage([photo, tmp.appendingPathComponent("sumiu.jpg")], into: root, on: Date()))
        let day = root.appendingPathComponent(AttachmentStaging.dayName(Date()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: day.path), [])
    }

    func testStagedPathsAreRealPathsLikeTheBotResolves() throws {
        let tmp = try scratch()
        let real = tmp.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = tmp.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let photo = tmp.appendingPathComponent("praia.jpg")
        try Data("x".utf8).write(to: photo)
        let staged = try AttachmentStaging.stage([photo], into: alias)
        XCTAssertTrue(staged[0].path.hasPrefix(real.path + "/"), staged[0].path)
    }

    func testMalformedItemShowsOnlyTheFileName() throws {
        let text = "[o Ale enviou 2 arquivo(s) pelo Wisp, ja salvos nesta maquina:\n- /u/x/anexos/c.jpg (c.jpg, muitos bytes)\n- /u/x/anexos/z.pdf]\n\noi"
        let parsed = try XCTUnwrap(MessageAttachments.parse(text))
        XCTAssertEqual(parsed.items, [.failed(label: "c.jpg"), .failed(label: "z.pdf")])
    }

    func testABlockThatDoesNotParseStillHidesThePaths() throws {
        let broken = "[o Ale enviou 3 arquivo(s) pelo Telegram, ja salvos nesta maquina:\n- /u/x/a.jpg (a.jpg, 1 bytes)]\n\nolha"
        XCTAssertNil(MessageAttachments.parse(broken))
        XCTAssertEqual(MessageAttachments.unparsed(broken), MessageAttachments(origin: "", items: [], caption: "olha"))
        XCTAssertEqual(MessageAttachments.unparsed(broken)?.summary, "anexos · olha")
        XCTAssertNil(MessageAttachments.unparsed("[o Ale enviou 1 arquivo(s) pelo Wisp, ja salvos nesta maquina:\n- /a]\n\n(sem texto — veja o que é e me diga)")?.caption)
        XCTAssertNil(MessageAttachments.unparsed("oi"))
        XCTAssertNil(MessageAttachments.unparsed("[o Joao enviou o relatorio ontem]\n\nveja"))
        XCTAssertNil(MessageAttachments.unparsed("[o time enviou isso"))
        XCTAssertNotNil(MessageAttachments.unparsed("[o Rita enviou 2 arquivo(s) pelo Telegram, ja salvos nesta maquina:\n- quebrado]\n\nolha"))
    }

    func testFirstMessageNameForAttachmentOnlyMessages() {
        XCTAssertEqual(MessageAttachments.firstMessageName(caption: "olha", names: ["a.jpg"]), "olha")
        XCTAssertEqual(MessageAttachments.firstMessageName(caption: "", names: ["a.jpg", "b.HEIC"]), "foto")
        XCTAssertEqual(MessageAttachments.firstMessageName(caption: "", names: ["a.jpg", "b.pdf"]), "arquivo")
    }
}
