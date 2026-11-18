import XCTest
@testable import WispCore

final class SetupModelsTests: XCTestCase {
    func testDecodesNeedsUser() throws {
        let json = """
        {"step":"system","status":"needs_user","summary":"Falta o Command Line Tools.",
         "details":[{"command":"xcode-select -p","exit":2,"output":"missing"}],"data":{"k":"v"}}
        """
        let report = try JSONDecoder().decode(SetupReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.status, .needsUser)
        XCTAssertEqual(report.step, "system")
        XCTAssertEqual(report.details, [SetupDetail(command: "xcode-select -p", exit: 2, output: "missing")])
        XCTAssertEqual(report.data, ["k": "v"])
    }

    func testUnknownStatusFailsDecode() {
        let json = #"{"step":"x","status":"weird","summary":"","details":[],"data":{}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(SetupReport.self, from: Data(json.utf8)))
    }

    func testDecodesDoctor() throws {
        let json = #"{"version":1,"checks":[{"id":"git","ok":false,"summary":"sem git","step":"system"},{"id":"x","ok":true,"summary":"ok"}]}"#
        let doctor = try JSONDecoder().decode(DoctorReport.self, from: Data(json.utf8))
        XCTAssertEqual(doctor.checks.map(\.step), ["system", nil])
        XCTAssertEqual(doctor.checks.map(\.data), [[:], [:]])
    }

    func testDecodesDoctorCheckData() throws {
        let json = #"{"version":1,"checks":[{"id":"telegram","ok":false,"summary":"parado","step":"telegram","data":{"job":"installed"}}]}"#
        let doctor = try JSONDecoder().decode(DoctorReport.self, from: Data(json.utf8))
        XCTAssertEqual(doctor.checks.first?.data, ["job": "installed"])
    }

    func testSetupStateSavesAndLoadsWithTheSharedCoders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-state-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("Wisp/setup.json")
        XCTAssertNil(try SetupState.load(from: url))
        let state = SetupState(completed: ["system"], skipped: ["telegram"], finishedAt: Date(timeIntervalSince1970: 100))
        try state.save(to: url)
        XCTAssertEqual(try SetupState.load(from: url), state)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("1970-01-01T00:01:40Z"))
        try Data("{".utf8).write(to: url)
        XCTAssertThrowsError(try SetupState.load(from: url))
    }
}
