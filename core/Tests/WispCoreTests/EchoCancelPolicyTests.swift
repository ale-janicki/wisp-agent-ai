import XCTest
@testable import WispCore

final class EchoCancelPolicyTests: XCTestCase {
    func testAutomaticCancelsOnlyOnTheBuiltInSpeakers() {
        XCTAssertTrue(EchoCancelPolicy.shouldCancel(mode: .automatic, outputIsBuiltInSpeakers: true))
        XCTAssertFalse(EchoCancelPolicy.shouldCancel(mode: .automatic, outputIsBuiltInSpeakers: false))
    }

    func testAlwaysAndNeverIgnoreTheOutput() {
        for speakers in [true, false] {
            XCTAssertTrue(EchoCancelPolicy.shouldCancel(mode: .always, outputIsBuiltInSpeakers: speakers))
            XCTAssertFalse(EchoCancelPolicy.shouldCancel(mode: .never, outputIsBuiltInSpeakers: speakers))
        }
    }

    func testPickerShowsTheThreeChoicesInOrder() {
        XCTAssertEqual(EchoCancelMode.allCases.map(\.label), ["Automático", "Sempre", "Nunca"])
    }

    private func decode(_ json: String) throws -> MeetingSettings {
        try JSONDecoder().decode(MeetingSettings.self, from: Data(json.utf8))
    }

    func testMissingSettingDefaultsToAutomatic() throws {
        XCTAssertEqual(try decode("{}").echoCancel, .automatic)
        XCTAssertEqual(MeetingSettings().echoCancel, .automatic)
        let old = try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime"}"#.utf8))
        XCTAssertEqual(old.meetings.echoCancel, .automatic)
    }

    func testOldBoolOnBecomesAutomaticAndOffBecomesNever() throws {
        XCTAssertEqual(try decode(#"{"echoCancel":true}"#).echoCancel, .automatic)
        XCTAssertEqual(try decode(#"{"echoCancel":false}"#).echoCancel, .never)
        XCTAssertEqual(try decode(#"{"cancelEcho":true}"#).echoCancel, .automatic)
        XCTAssertEqual(try decode(#"{"cancelEcho":false}"#).echoCancel, .never)
    }

    func testModeRoundTripsAndJunkFallsBackToAutomatic() throws {
        for mode in EchoCancelMode.allCases {
            var settings = MeetingSettings()
            settings.echoCancel = mode
            let data = try JSONEncoder().encode(settings)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""echoCancel":"\#(mode.rawValue)""#))
            XCTAssertEqual(try JSONDecoder().decode(MeetingSettings.self, from: data).echoCancel, mode)
        }
        XCTAssertEqual(try decode(#"{"echoCancel":"loud","autoSummary":false}"#).echoCancel, .automatic)
        XCTAssertFalse(try decode(#"{"echoCancel":"loud","autoSummary":false}"#).autoSummary)
    }

    // MARK: output route

    private let headphonesSource: UInt32 = 0x6864_706E

    func testDataSourceDecidesWhenReadable() {
        XCTAssertTrue(EchoCancelPolicy.isBuiltInSpeakers(
            builtInTransport: true, dataSource: EchoCancelPolicy.internalSpeakerSource, name: "MacBook Air Speakers", uid: "BuiltInSpeakerDevice"
        ))
        XCTAssertFalse(EchoCancelPolicy.isBuiltInSpeakers(
            builtInTransport: true, dataSource: headphonesSource, name: "MacBook Air Speakers", uid: "BuiltInSpeakerDevice"
        ))
    }

    func testUnreadableSourceFallsBackToTheDeviceNameOrUID() {
        XCTAssertTrue(EchoCancelPolicy.isBuiltInSpeakers(builtInTransport: true, dataSource: nil, name: "MacBook Air Speakers", uid: "x"))
        XCTAssertTrue(EchoCancelPolicy.isBuiltInSpeakers(builtInTransport: true, dataSource: nil, name: "Alto-falantes do MacBook", uid: "x"))
        XCTAssertTrue(EchoCancelPolicy.isBuiltInSpeakers(builtInTransport: true, dataSource: nil, name: "Saída", uid: "BuiltInSpeakerDevice"))
        XCTAssertFalse(EchoCancelPolicy.isBuiltInSpeakers(
            builtInTransport: true, dataSource: nil, name: "External Headphones", uid: "BuiltInHeadphoneOutputDevice"
        ))
    }

    func testOtherTransportsAreNeverTheSpeakers() {
        XCTAssertFalse(EchoCancelPolicy.isBuiltInSpeakers(
            builtInTransport: false, dataSource: EchoCancelPolicy.internalSpeakerSource, name: "AirPods Speakers", uid: "Speaker"
        ))
    }

    // MARK: retry gate

    func testFailureOnARouteBlocksRetryUntilTheRouteChanges() {
        var gate = VoiceProcessingRetryGate()
        XCTAssertFalse(gate.isBlocked)
        gate.recordFailure(route: "BuiltInSpeakerDevice|ispk")
        XCTAssertTrue(gate.isBlocked)
        gate.routeChanged(to: "BuiltInSpeakerDevice|ispk")
        XCTAssertTrue(gate.isBlocked, "same route: no retry")
        gate.routeChanged(to: "BuiltInHeadphoneOutputDevice|none")
        XCTAssertFalse(gate.isBlocked, "another route: retry allowed")
    }
}
