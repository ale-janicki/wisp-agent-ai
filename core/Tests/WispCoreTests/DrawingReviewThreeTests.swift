import XCTest
@testable import WispCore

final class DrawingReviewThreeTests: XCTestCase {
    private func element(_ id: String, _ text: String) -> String {
        "{\"id\":\"\(id)\",\"type\":\"text\",\"text\":\"\(text)\",\"originalText\":\"\(text)\"}"
    }

    private func sample(region: String, ids: [(String, String)], trailer: String = "") -> String {
        let elements = ids.map { element($0.0, $0.1) }.joined(separator: ",")
        return "# Excalidraw Data\n\n## Text Elements\n\(region)%%\n## Drawing\n```json\n{\"type\":\"excalidraw\",\"version\":2,\"elements\":[\(elements)],\"appState\":{},\"files\":{}}\n```\n%%\(trailer)"
    }

    private func head(_ text: String) -> String {
        text.components(separatedBy: "%%\n## Drawing\n")[0]
    }

    func testTextAfterTheLastAnchorIsKeptInPlace() throws {
        let region = "Hello ^AAAA1111\n\nfragment after the last anchor\nsecond line\n\n"
        let original = sample(region: region, ids: [("AAAA1111", "Hello")])
        let file = try ExcalidrawFile.parse(original, container: .markdown)
        XCTAssertEqual(head(file.serialized()), head(original))
        var edited = file
        var scene = edited.scene
        var elements = try XCTUnwrap(scene["elements"]?.arrayValue)
        elements[0]["text"] = .string("Hello edited")
        elements[0]["originalText"] = .string("Hello edited")
        scene["elements"] = .array(elements)
        try edited.apply(sceneJSON: scene.serialized()) { _ in "" }
        XCTAssertTrue(edited.serialized().contains("Hello edited ^AAAA1111\n\nfragment after the last anchor\nsecond line\n\n%%"))
    }

    func testStrayTextBetweenAnchorsIsNotFoldedIntoTheNextElement() throws {
        let region = "Hello ^AAAA1111\n\nDead one ^DEAD0000\n\nStray paragraph\n\nWorld ^BBBB2222\n\n"
        let original = sample(region: region, ids: [("AAAA1111", "Hello"), ("BBBB2222", "World")])
        let file = try ExcalidrawFile.parse(original, container: .markdown)
        XCTAssertEqual(file.textElements.first { $0.id == "BBBB2222" }?.raw, "World")
        let written = file.serialized()
        XCTAssertTrue(written.contains("Stray paragraph\n\nWorld ^BBBB2222\n\n"))
        XCTAssertFalse(written.contains("Dead one"))
        XCTAssertEqual(try ExcalidrawFile.parse(written, container: .markdown).serialized(), written)
    }

    func testSavingWithoutTextChangesLeavesTheTextElementsAlone() throws {
        let region = "Hello ^AAAA1111\n\nhalf an element\n\n"
        let trailer = "\n\n## Log\nWorld ^BBBB2222\n"
        let original = sample(region: region, ids: [("AAAA1111", "Hello"), ("BBBB2222", "World"), ("CCCC3333", "Other")], trailer: trailer)
        var file = try ExcalidrawFile.parse(original, container: .markdown)
        XCTAssertEqual(file.serialized().components(separatedBy: "%%\n## Drawing")[0], original.components(separatedBy: "%%\n## Drawing")[0])
        var scene = file.scene
        scene["appState"]?["viewBackgroundColor"] = .string("#fafafa")
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }
        let written = file.serialized()
        XCTAssertEqual(head(written), head(original))
        XCTAssertEqual(written.components(separatedBy: " ^BBBB2222").count - 1, 1)
        XCTAssertFalse(head(written).contains("^CCCC3333"))
        XCTAssertTrue(written.hasSuffix(trailer))
    }

    func testChangedAndNewElementsAreEmittedButNeverWhenTheTrailerAlreadyAnchorsThem() throws {
        let trailer = "\n\n## Log\nWorld ^BBBB2222\n"
        let original = sample(region: "Hello ^AAAA1111\n\n", ids: [("AAAA1111", "Hello"), ("BBBB2222", "World"), ("CCCC3333", "Other")], trailer: trailer)
        var file = try ExcalidrawFile.parse(original, container: .markdown)
        var scene = file.scene
        var elements = try XCTUnwrap(scene["elements"]?.arrayValue)
        for index in [1, 2] {
            elements[index]["text"] = .string("changed \(index)")
            elements[index]["originalText"] = .string("changed \(index)")
        }
        elements.append(try JSONValue.parse(element("DDDD4444", "brand new")))
        scene["elements"] = .array(elements)
        try file.apply(sceneJSON: scene.serialized()) { _ in "" }
        let written = head(file.serialized())
        XCTAssertFalse(written.contains("^BBBB2222"))
        XCTAssertTrue(written.contains("changed 2 ^CCCC3333"))
        XCTAssertTrue(written.contains("brand new ^DDDD4444"))
        XCTAssertTrue(written.contains("Hello ^AAAA1111"))
    }

    func testAStrayParagraphBeforeADeadAnchorIsKept() throws {
        let original = sample(region: "Hello ^AAAA1111\n\nnotes\n\nDead ^DEAD0000\n\n", ids: [("AAAA1111", "Hello")])
        let file = try ExcalidrawFile.parse(original, container: .markdown)
        let full = file.serialized()
        let written = head(full)
        XCTAssertTrue(written.contains("Hello ^AAAA1111\n\nnotes\n\n"))
        XCTAssertFalse(written.contains("Dead"))
        XCTAssertEqual(head(try ExcalidrawFile.parse(full, container: .markdown).serialized()), written)
    }

    func testAStrayParagraphBeforeADeadAnchorTravelsToTheNextLiveElement() throws {
        let original = sample(region: "Hello ^AAAA1111\n\nnotes\n\nDead ^DEAD0000\n\nWorld ^BBBB2222\n\n", ids: [("AAAA1111", "Hello"), ("BBBB2222", "World")])
        let written = head(try ExcalidrawFile.parse(original, container: .markdown).serialized())
        XCTAssertTrue(written.contains("Hello ^AAAA1111\n\nnotes\n\nWorld ^BBBB2222\n\n"))
    }

    @MainActor
    func testAClosingModelStaysInTheQuitRegistryUntilItIsFinished() async {
        let registry = QuitFlush()
        let closer = DrawingClosingTracker()
        let log = Log()
        let token = registry.register {
            if closer.isClosing { await closer.waitUntilFinished(timeout: .seconds(3)) }
            log.lines.append(closer.isFinished ? "flushed-after-close" : "flushed-early")
        }
        closer.begin()
        XCTAssertFalse(registry.isEmpty)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            registry.unregister(token)
            closer.finish()
        }
        await registry.flushAll(timeout: .seconds(3))
        XCTAssertEqual(log.lines, ["flushed-after-close"])
        XCTAssertTrue(registry.isEmpty)
    }

    func testAtomicWriteTreatsAVanishedFileAsChanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-gone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.canvas")
        XCTAssertThrowsError(try AtomicFile.write(Data("x".utf8), to: file, root: folder, expectingHash: DrawingFileState.hash(of: Data("old".utf8)))) {
            XCTAssertEqual($0 as? AtomicFile.Failure, .changedOnDisk)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        try AtomicFile.write(Data("x".utf8), to: file, root: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    func testQuitFlushRunsEveryFlusherAndWaitsForThem() async {
        let registry = QuitFlush()
        XCTAssertTrue(registry.isEmpty)
        let log = Log()
        let first = registry.register {
            try? await Task.sleep(for: .milliseconds(80))
            log.lines.append("first")
        }
        registry.register { log.lines.append("second") }
        XCTAssertFalse(registry.isEmpty)
        await registry.flushAll(timeout: .seconds(2))
        XCTAssertEqual(Set(log.lines), ["first", "second"])
        registry.unregister(first)
        log.lines = []
        await registry.flushAll(timeout: .seconds(2))
        XCTAssertEqual(log.lines, ["second"])
    }

    @MainActor
    func testQuitFlushGivesUpAfterTheTimeout() async {
        let registry = QuitFlush()
        registry.register { try? await Task.sleep(for: .seconds(30)) }
        let started = ContinuousClock.now
        await registry.flushAll(timeout: .milliseconds(200))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    @MainActor
    func testCloseWaitReturnsWhenTheLateSaveLands() async {
        let state = Log()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            state.lines.append("saved")
        }
        let started = ContinuousClock.now
        await DrawingCloseWait.until(timeout: .seconds(3)) { !state.lines.isEmpty }
        XCTAssertEqual(state.lines, ["saved"])
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        let never = Log()
        let begin = ContinuousClock.now
        await DrawingCloseWait.until(timeout: .milliseconds(200)) { !never.lines.isEmpty }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - begin, .milliseconds(150))
    }

    @MainActor
    final class Log {
        var lines: [String] = []
    }
}

final class DrawingClosingMarkerTests: XCTestCase {
    func testAMissingClosingMarkerComesBackAsItWas() throws {
        let original = "# Excalidraw Data\n\n## Text Elements\nHello ^AAAA1111\n\n## Drawing\n```json\n{\"type\":\"excalidraw\",\"version\":2,\"elements\":[{\"id\":\"AAAA1111\",\"type\":\"text\",\"text\":\"Hello\",\"originalText\":\"Hello\"}],\"appState\":{},\"files\":{}}\n```\n%%"
        let file = try ExcalidrawFile.parse(original, container: .markdown)
        XCTAssertEqual(file.serialized().components(separatedBy: "```json")[0], original.components(separatedBy: "```json")[0])
    }
}
