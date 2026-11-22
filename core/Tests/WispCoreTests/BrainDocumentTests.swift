import XCTest
@testable import WispCore

final class BrainDocumentTests: XCTestCase {
    func testRoundTripsByteForByte() {
        let samples = [
            "---\ntitle: A\ntags:\n  - x\n  - y\n---\n# Body\n",
            "---\n---\n",
            "---\na: 1\n---",
            "no front\nmatter\n",
            "---  \nkey:   spaced value  \n---\n\n\nend",
            "---\nnot closed\n# h\n",
        ]
        for sample in samples { XCTAssertEqual(BrainDocument(sample).text, sample) }
    }

    func testReadsScalarsAndBothListShapes() {
        let document = BrainDocument("---\naliases: [One, \"Two words\"]\ntags:\n  - a\n  - b\nstatus: active\nnested:\n  k: v\n---\nbody")
        XCTAssertEqual(document.list("aliases"), ["One", "Two words"])
        XCTAssertEqual(document.list("tags"), ["a", "b"])
        XCTAssertEqual(document.property("status"), .text("active"))
        XCTAssertEqual(document.property("nested"), .complex("  k: v"))
        XCTAssertEqual(document.body, "body")
    }

    func testEditingOneKeyLeavesEveryOtherLineUntouched() {
        let source = "---\n# keep this comment\ntitle:    \"Spaced\"\naliases: [One]\ntags:\n  - a\n---\nbody\n"
        var document = BrainDocument(source)
        document.set("aliases", to: .list(["One", "Two"]))
        document.set("tags", to: .list(["a", "b"]))
        XCTAssertEqual(document.text, "---\n# keep this comment\ntitle:    \"Spaced\"\naliases: [One, Two]\ntags:\n  - a\n  - b\n---\nbody\n")
    }

    func testAddsAKeyAndCreatesFrontmatterWhenThereIsNone() {
        var document = BrainDocument("# Title\n")
        document.set("status", to: .text("draft"))
        document.set("tags", to: .list(["x"]))
        XCTAssertEqual(document.text, "---\nstatus: draft\ntags:\n  - x\n---\n# Title\n")
        document.remove("status")
        XCTAssertEqual(document.text, "---\ntags:\n  - x\n---\n# Title\n")
    }

    func testQuotesValuesThatYamlWouldMisread() {
        var document = BrainDocument("---\na: 1\n---\n")
        document.set("title", to: .text("Plan: v2"))
        XCTAssertEqual(document.property("title"), .text("Plan: v2"))
        XCTAssertTrue(document.text.contains("title: \"Plan: v2\""))
    }

    func testBodyEditKeepsFrontmatter() {
        var document = BrainDocument("---\na: 1\n---\nold")
        document.setBody("new\n")
        XCTAssertEqual(document.text, "---\na: 1\n---\nnew\n")
    }
}
