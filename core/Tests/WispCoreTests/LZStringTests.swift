import XCTest
@testable import WispCore

final class LZStringTests: XCTestCase {
    private let vectors: [(String, String)] = [
        ("Hello World", "BIUwNmD2AEDqkCcwBMg="),
        ("a", "IZA="),
        ("aaaaaaaaaaaaaaaa", "IY1/EA=="),
        ("Olá, mundo — ação ✓ 😀", "PIGwhwNABAtgrgOwCYHsqBQCKBDA5wY7UGRyKQXg3AAPaA=="),
        ("{\"a\":[1,2,3]}", "N4IghiBcDaCMA0AmeBmAugXyA==="),
        ("abababababababababab", "IYI17SIo"),
        ("", "Q==="),
    ]

    func testCompressMatchesTheReferenceLibrary() {
        for (input, expected) in vectors {
            XCTAssertEqual(LZString.compressToBase64(input), expected, input)
        }
    }

    func testDecompressMatchesTheReferenceLibrary() {
        for (input, encoded) in vectors where !input.isEmpty {
            XCTAssertEqual(LZString.decompressFromBase64(encoded), input)
        }
    }

    func testLongSceneMatchesTheReferenceLibraryOutput() throws {
        let json = try String(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "Fixtures/drawings/neutral", withExtension: "excalidraw")), encoding: .utf8)
        let packed = LZString.compressToBase64(json)
        XCTAssertEqual(LZString.decompressFromBase64(packed), json)
        XCTAssertLessThan(packed.count, json.count)
    }

    func testRoundTripOfVariedInputs() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abcdefghij \n\t{}[]\"éçã—😀日本語")
        for length in [1, 2, 3, 17, 255, 256, 257, 1000, 5000] {
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
            XCTAssertEqual(LZString.decompressFromBase64(LZString.compressToBase64(text)), text, "length \(length)")
        }
    }

    func testEmptyAndCorruptedInputAreNotAScene() {
        XCTAssertNil(LZString.decompressFromBase64(""))
        let decoded = LZString.decompressFromBase64("!!!!")
        XCTAssertTrue(decoded == nil || decoded == "")
    }

    func testDecompressionIsCapped() throws {
        let text = String(repeating: "abcdefgh", count: 2000)
        let packed = LZString.compressToBase64(text)
        XCTAssertThrowsError(try LZString.decompressChecked(fromBase64: packed, maxUnits: 1000)) {
            XCTAssertEqual($0 as? LZString.DecompressError, .tooLarge)
        }
        XCTAssertEqual(try LZString.decompressChecked(fromBase64: packed, maxUnits: 100_000), text)
        XCTAssertThrowsError(try LZString.decompressChecked(fromBase64: "", maxUnits: 10))
    }
}
