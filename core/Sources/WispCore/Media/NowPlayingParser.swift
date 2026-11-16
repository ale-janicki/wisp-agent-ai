import Foundation

public struct NowPlayingTrack: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    public var position: TimeInterval
    public var duration: TimeInterval
    public var artworkURL: URL?

    public init(
        title: String,
        artist: String,
        album: String,
        isPlaying: Bool,
        position: TimeInterval,
        duration: TimeInterval,
        artworkURL: URL? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
        self.artworkURL = artworkURL
    }
}

public enum NowPlayingParser {
    public enum DurationUnit: Sendable { case seconds, milliseconds }

    public static let separator = "\u{1F}"
    private static let fieldCount = 7
    private static let playingStates: Set<String> = ["playing", "fast forwarding", "rewinding"]

    public static func parse(_ raw: String, durationUnit: DurationUnit) -> NowPlayingTrack? {
        let fields = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: separator)
        guard fields.count == fieldCount else { return nil }

        let state = fields[0].lowercased()
        guard state == "paused" || playingStates.contains(state) else { return nil }
        let title = fields[1].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty,
              let position = number(fields[4]),
              let rawDuration = number(fields[5])
        else { return nil }

        let duration = max(0, durationUnit == .milliseconds ? rawDuration / 1000 : rawDuration)
        let artwork = fields[6].trimmingCharacters(in: .whitespaces)
        return NowPlayingTrack(
            title: title,
            artist: fields[2],
            album: fields[3],
            isPlaying: playingStates.contains(state),
            position: min(max(0, position), duration),
            duration: duration,
            artworkURL: artwork.isEmpty ? nil : URL(string: artwork)
        )
    }

    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}
