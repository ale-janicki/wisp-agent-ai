import XCTest
@testable import WispCore

final class BrainReadOnlyPolicyTests: XCTestCase {
    func testReadOnlyTurnsEmbedsIntoLinkTextAndLocksTasks() {
        XCTAssertEqual(BrainReadOnlyPolicy.embedMode(readOnly: true), .linkText)
        XCTAssertEqual(BrainReadOnlyPolicy.embedMode(readOnly: false), .render)
        XCTAssertFalse(BrainReadOnlyPolicy.tasksAreInteractive(readOnly: true))
        XCTAssertTrue(BrainReadOnlyPolicy.tasksAreInteractive(readOnly: false))
    }

    func testFindsBlockEmbedsEvenNestedInListsQuotesAndCallouts() {
        let text = "- [ ] a\n\n![[nota-privada]]\n\n> ![[desenho.excalidraw]]\n\n- item\n  ![[outra]]\n"
        let nodes = BrainMarkdown.parse(text).nodes
        XCTAssertTrue(BrainReadOnlyPolicy.containsEmbed(nodes))
        XCTAssertFalse(BrainReadOnlyPolicy.containsEmbed(BrainMarkdown.parse("# Resumo\n\n- [ ] ação\n\ntexto [[link]]").nodes))
    }
}
