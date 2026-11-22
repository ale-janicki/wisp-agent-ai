import XCTest
@testable import WispCore

final class JSONCanvasTests: XCTestCase {
    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/drawings/neutral", withExtension: "canvas"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesAllNodeTypesAndEdges() throws {
        let canvas = try JSONCanvas.parse(fixture())
        XCTAssertEqual(canvas.nodes.map(\.kind), [.text, .file, .link, .group])
        XCTAssertEqual(canvas.nodes[0].text, "# Título\nTexto **exemplo**")
        XCTAssertEqual(canvas.nodes[0].color, "4")
        XCTAssertEqual(canvas.nodes[1].linkTarget, "notas/nota-exemplo.md#Seção")
        XCTAssertEqual(canvas.nodes[2].url, "https://example.com")
        XCTAssertEqual(canvas.nodes[3].label, "Grupo")
        XCTAssertEqual(canvas.edges.count, 2)
        XCTAssertEqual(canvas.edges[0].label, "liga")
        XCTAssertTrue(canvas.edges[0].toArrow)
        XCTAssertFalse(canvas.edges[0].fromArrow)
        XCTAssertTrue(canvas.edges[1].fromArrow)
        XCTAssertFalse(canvas.edges[1].toArrow)
    }

    func testUnchangedCanvasComesBackByteForByteWithUnknownKeys() throws {
        let original = try fixture()
        let canvas = try JSONCanvas.parse(original)
        XCTAssertEqual(canvas.serialized(), original)
        XCTAssertTrue(canvas.serialized().contains("\"customFutureKey\":{\"a\":1}"))
    }

    func testMovingANodeChangesOnlyItsPosition() throws {
        var canvas = try JSONCanvas.parse(fixture())
        canvas.moveNode("n3", to: (x: 12.5, y: -40))
        let reread = try JSONCanvas.parse(canvas.serialized())
        XCTAssertEqual(reread.node("n3")?.x, 12.5)
        XCTAssertEqual(reread.node("n3")?.y, -40)
        XCTAssertEqual(reread.node("n3")?.url, "https://example.com")
        XCTAssertEqual(reread.nodes.count, 4)
        XCTAssertEqual(reread.node("n1"), try JSONCanvas.parse(fixture()).node("n1"))
    }

    func testRemovingANodeRemovesItsEdges() throws {
        var canvas = try JSONCanvas.parse(fixture())
        canvas.removeNode("n1")
        XCTAssertEqual(canvas.nodes.count, 3)
        XCTAssertTrue(canvas.edges.isEmpty)
    }

    func testConnectPicksFacingSides() throws {
        var canvas = try JSONCanvas.parse(fixture())
        canvas.connect(from: "n2", to: "n3")
        let edge = try XCTUnwrap(canvas.edges.last)
        XCTAssertEqual(edge.fromNode, "n2")
        XCTAssertEqual(edge.toNode, "n3")
        XCTAssertEqual(edge.fromSide, .left)
        XCTAssertEqual(edge.toSide, .right)
        canvas.connect(from: "n2", to: "n2")
        XCTAssertEqual(canvas.edges.count, 3)
    }

    func testNewNodesAreAppendedOnTop() throws {
        var canvas = try JSONCanvas.parse(fixture())
        canvas.add(CanvasNode(id: "n9", kind: .text, x: 0, y: 500, width: 200, height: 80, text: "novo"))
        canvas.bringToFront("n1")
        XCTAssertEqual(canvas.nodes.last?.id, "n1")
        let reread = try JSONCanvas.parse(canvas.serialized())
        XCTAssertEqual(reread.node("n9")?.text, "novo")
        XCTAssertEqual(reread.node("n9")?.kind, .text)
    }

    func testGroupContainment() throws {
        let canvas = try JSONCanvas.parse(fixture())
        let group = try XCTUnwrap(canvas.node("n4"))
        XCTAssertTrue(group.contains(try XCTUnwrap(canvas.node("n1"))))
        XCTAssertFalse(group.contains(CanvasNode(id: "far", kind: .text, x: 900, y: 0, width: 10, height: 10)))
    }

    func testRejectsNonCanvasJSON() {
        XCTAssertThrowsError(try JSONCanvas.parse("[1,2]"))
        XCTAssertThrowsError(try JSONCanvas.parse("nope"))
        XCTAssertEqual(try JSONCanvas.parse("{}").nodes.count, 0)
    }

    func testEmptyCanvasSerializes() throws {
        let text = JSONCanvas.blank().serialized()
        XCTAssertEqual(text, "{\n\t\"nodes\":[],\n\t\"edges\":[]\n}")
        XCTAssertEqual(try JSONCanvas.parse(text), JSONCanvas.blank())
    }

    func testBoundsCoverEveryNode() throws {
        let bounds = try XCTUnwrap(JSONCanvas.parse(fixture()).bounds)
        XCTAssertEqual(bounds.x, -40)
        XCTAssertEqual(bounds.width, 700)
    }
}

final class JSONValueTests: XCTestCase {
    func testKeyOrderAndNumberFormattingAreKept() throws {
        let text = #"{"b":1.0,"a":[1e-7,-0.5,10],"c":{"z":null,"y":true}}"#
        let value = try JSONValue.parse(text)
        XCTAssertEqual(value.serialized(), text)
    }

    func testStringsEscapeRoundTrip() throws {
        let text = "{\"s\":\"a\\n\\t\\\"b\\\\ \\u00e9 \\ud83d\\ude00\"}"
        let value = try JSONValue.parse(text)
        XCTAssertEqual(value["s"]?.stringValue, "a\n\t\"b\\ é 😀")
        XCTAssertEqual(try JSONValue.parse(value.serialized()), value)
    }

    func testPrettyPrintingUsesTheGivenIndent() throws {
        let value = try JSONValue.parse(#"{"a":[1,2],"b":{},"c":[]}"#)
        XCTAssertEqual(value.serialized(indent: "\t"), "{\n\t\"a\": [\n\t\t1,\n\t\t2\n\t],\n\t\"b\": {},\n\t\"c\": []\n}")
    }

    func testRejectsBrokenInput() {
        for bad in ["{", "[1,]", "{\"a\" 1}", "\"x", "tru", "{} extra", "", "01x"] {
            XCTAssertThrowsError(try JSONValue.parse(bad), bad)
        }
    }

    func testSubscriptSetsAndRemoves() throws {
        var value = try JSONValue.parse(#"{"a":1}"#)
        value["b"] = .int(2)
        value["a"] = nil
        XCTAssertEqual(value.serialized(), #"{"b":2}"#)
    }
}
