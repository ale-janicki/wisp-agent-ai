import AppKit
import WispCore
import XCTest

@testable import Wisp

@MainActor
final class BlockOutputWidthTests: XCTestCase {
    func testOutputWrapsAtTheViewWidthNotAtTheInitialContainerWidth() {
        let view = BlockOutputTextView()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.setLines([StyledLine(text: "Found Developer Portal at acme-frontend/")], font: font, colors: AppSettings.shared.colors)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)

        XCTAssertEqual(view.textContainer?.size.width ?? 0, 800, accuracy: 0.5)
        let layout = try! XCTUnwrap(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        var fragments = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            fragments += fragment.textLineFragments.count
            return true
        }
        XCTAssertEqual(fragments, 1, "a 42-char line in an 800pt pane must render on one line")
    }
}
