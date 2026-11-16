import XCTest
@testable import WispCore

final class NowPlayingParserTests: XCTestCase {
    private func line(_ fields: [String]) -> String {
        fields.joined(separator: NowPlayingParser.separator)
    }

    func testPlayingSpotifyConvertsMilliseconds() throws {
        let raw = line(["playing", "Song", "Artist", "Album", "12.5", "200000", "https://i.scdn.co/image/abc"])
        let track = try XCTUnwrap(NowPlayingParser.parse(raw, durationUnit: .milliseconds))
        XCTAssertEqual(track.title, "Song")
        XCTAssertEqual(track.artist, "Artist")
        XCTAssertEqual(track.album, "Album")
        XCTAssertTrue(track.isPlaying)
        XCTAssertEqual(track.position, 12.5)
        XCTAssertEqual(track.duration, 200)
        XCTAssertEqual(track.artworkURL, URL(string: "https://i.scdn.co/image/abc"))
    }

    func testPausedMusicWithCommaDecimalsAndNoArtworkURL() throws {
        let raw = line(["paused", "Song", "Artist", "Album", "3,25", "180,5", ""]) + "\n"
        let track = try XCTUnwrap(NowPlayingParser.parse(raw, durationUnit: .seconds))
        XCTAssertFalse(track.isPlaying)
        XCTAssertEqual(track.position, 3.25)
        XCTAssertEqual(track.duration, 180.5)
        XCTAssertNil(track.artworkURL)
    }

    func testPositionIsClampedToDuration() throws {
        let raw = line(["playing", "Song", "Artist", "Album", "250", "200", ""])
        let track = try XCTUnwrap(NowPlayingParser.parse(raw, durationUnit: .seconds))
        XCTAssertEqual(track.position, 200)
    }

    func testEmptyAndStoppedAreNil() {
        XCTAssertNil(NowPlayingParser.parse("", durationUnit: .seconds))
        XCTAssertNil(NowPlayingParser.parse("stopped", durationUnit: .seconds))
        XCTAssertNil(NowPlayingParser.parse(line(["playing", "", "Artist", "Album", "1", "2", ""]), durationUnit: .seconds))
    }

    func testGarbageIsNil() {
        XCTAssertNil(NowPlayingParser.parse("hello world", durationUnit: .seconds))
        XCTAssertNil(NowPlayingParser.parse(line(["flying", "Song", "Artist", "Album", "1", "2", ""]), durationUnit: .seconds))
        XCTAssertNil(NowPlayingParser.parse(line(["playing", "Song", "Artist", "Album", "abc", "2", ""]), durationUnit: .seconds))
        XCTAssertNil(NowPlayingParser.parse(line(["playing", "Song", "Artist"]), durationUnit: .seconds))
    }
}
