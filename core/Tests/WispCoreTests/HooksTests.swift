import XCTest
@testable import WispCore

final class HooksTests: XCTestCase {
    private let json = """
    {"hooks":[
      {"id":"a","event":"Stop","matcher":null,"command":"/x/stop.sh","script":"stop.sh","summary":"fecha o turno","enabled":true,"locked":false,"missing":false},
      {"id":"b","event":"SessionStart","matcher":"startup","command":"echo hi","script":null,"summary":null,"enabled":false,"locked":true,"missing":false},
      {"id":"c","event":"Custom","command":"\(String(repeating: "z", count: 100))","script":"gone.sh","enabled":true,"locked":false,"missing":true},
      {"id":"d","event":"SessionStart","command":"b.sh","script":"b.sh","summary":"s","enabled":true,"locked":false,"missing":false}
    ],"orphans":[{"script":"lost.sh","summary":null}]}
    """

    func testDecodesAndGroupsByLifecycleThenUnknown() throws {
        let report = try HooksReport.parse(Data(json.utf8))
        XCTAssertEqual(report.hooks.count, 4)
        XCTAssertEqual(report.orphans, [HookOrphan(script: "lost.sh")])
        XCTAssertEqual(report.groups.map(\.title), ["Início da sessão", "Fim do turno", "Custom"])
        XCTAssertEqual(report.groups[0].hooks.map(\.id), ["b", "d"])
        XCTAssertTrue(report.hooks[1].locked)
        XCTAssertFalse(report.hooks[1].enabled)
    }

    func testTitleAndDetail() throws {
        let hooks = try HooksReport.parse(Data(json.utf8)).hooks
        XCTAssertEqual(hooks[0].title, "stop.sh")
        XCTAssertEqual(hooks[0].detail, "fecha o turno")
        XCTAssertEqual(hooks[1].title, "echo hi")
        XCTAssertEqual(hooks[1].detail, "startup")
        XCTAssertEqual(HookEntry(id: "x", event: "Stop", matcher: "Bash", command: "c", summary: "s").detail, "s · Bash")
        let long = HookEntry(id: "y", event: "Stop", command: String(repeating: "q", count: 100))
        XCTAssertEqual(long.title.count, HookEntry.titleLimit)
        XCTAssertTrue(long.title.hasSuffix("…"))
    }

    func testRejectsWrongShapeAndBuildsCommand() {
        XCTAssertThrowsError(try HooksReport.parse(Data("[1]".utf8)))
        XCTAssertEqual(HookCommand.build("hooks-tool disable {id}", id: "it's"), "hooks-tool disable 'it'\\''s'")
    }
}
