import XCTest
@testable import WispCore

final class DrawingRealFilesTests: XCTestCase {
    private var sourceFolder: URL? {
        ProcessInfo.processInfo.environment["WISP_REAL_DRAWINGS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func copies(matching suffix: String) throws -> (root: URL, files: [URL]) {
        let source = try XCTUnwrap(sourceFolder)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var files: [URL] = []
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
        var index = 0
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) {
            let copy = root.appendingPathComponent("\(index)-\(url.lastPathComponent)")
            try FileManager.default.copyItem(at: url, to: copy)
            files.append(copy)
            index += 1
        }
        return (root, files)
    }

    func testExcalidrawCopiesRoundTrip() throws {
        try XCTSkipIf(sourceFolder == nil, "WISP_REAL_DRAWINGS_DIR not set")
        let (root, files) = try copies(matching: ".excalidraw.md")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(files.isEmpty)
        for url in files {
            let original = try String(contentsOf: url, encoding: .utf8)
            let parsed = try ExcalidrawFile.load(from: url)
            let rendered = parsed.serialized()
            let reparsed = try ExcalidrawFile.parse(rendered, container: .markdown)
            XCTAssertEqual(parsed.scene, reparsed.scene, url.lastPathComponent)
            XCTAssertEqual(parsed.header, reparsed.header)
            XCTAssertEqual(parsed.trailer, reparsed.trailer)
            XCTAssertEqual(parsed.embeddedFiles, reparsed.embeddedFiles)
            XCTAssertEqual(parsed.encoding, reparsed.encoding)
            XCTAssertEqual(rendered, original, "\(url.lastPathComponent): bytes differ")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(parsed.scene.serialized().utf8)) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: Data(reparsed.scene.serialized(indent: "\t").utf8)) as? NSDictionary)
            try parsed.write(to: url)
            let afterWrite = try ExcalidrawFile.load(from: url)
            XCTAssertEqual(afterWrite.scene, parsed.scene)
            print("REALFILE \(url.lastPathComponent) encoding=\(parsed.encoding) elements=\(parsed.elements.count) texts=\(parsed.textElements.count) bytesIdentical=\(rendered == original)")
        }
    }

    func testCanvasCopiesRoundTrip() throws {
        try XCTSkipIf(sourceFolder == nil, "WISP_REAL_DRAWINGS_DIR not set")
        let (root, files) = try copies(matching: ".canvas")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(files.isEmpty)
        for url in files {
            let original = try String(contentsOf: url, encoding: .utf8)
            let canvas = try JSONCanvas.load(from: url)
            let rendered = canvas.serialized()
            XCTAssertEqual(try JSONValue.parse(rendered), try JSONValue.parse(original), url.lastPathComponent)
            try canvas.write(to: url)
            XCTAssertEqual(try JSONCanvas.load(from: url), canvas)
            print("REALFILE \(url.lastPathComponent) nodes=\(canvas.nodes.count) edges=\(canvas.edges.count) bytesIdentical=\(rendered == original)")
        }
    }
}
