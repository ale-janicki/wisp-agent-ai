import SwiftUI
import WispCore

struct MediaCardView: View {
    enum Style { case tile, large, compact }

    @ObservedObject var media: NowPlayingService
    var style: Style

    var body: some View {
        if let player = media.player, let track = media.track {
            switch style {
            case .tile: tile(track)
            case .large: large(track, player: player).card()
            case .compact: compact(track, player: player).card()
            }
        } else if style == .compact {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: media.playerNeedingPermission == nil ? "music.note" : "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 36, height: 36)
                    .background(Theme.surfaceHi, in: Circle())
                if let player = media.playerNeedingPermission {
                    AutomationPromptView(media: media, player: player)
                } else {
                    Text(emptySentence)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        } else if style == .tile {
            Group {
                if let player = media.playerNeedingPermission {
                    AutomationPromptView(media: media, player: player, centered: true)
                } else {
                    sentence
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: media.playerNeedingPermission == nil ? "music.note" : "lock.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surface, in: Circle())
                    .overlay { Circle().strokeBorder(Theme.stroke, lineWidth: 1) }
                if let player = media.playerNeedingPermission {
                    AutomationPromptView(media: media, player: player, centered: true)
                } else {
                    sentence
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sentence: some View {
        Text(emptySentence)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Space.l)
    }

    private var emptySentence: String {
        if let running = media.runningPlayer { return "Nada tocando no \(running.name)" }
        return "Abra o Spotify ou o Music para ver o que está tocando"
    }

    // MARK: Tile

    private func tile(_ track: NowPlayingTrack) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Artwork(media: media, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    ProgressRow(track: track)
                        .padding(.top, Theme.Space.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Controls(media: media, track: track, small: 28, main: 36)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Compact

    private func compact(_ track: NowPlayingTrack, player: MediaPlayer) -> some View {
        HStack(spacing: Theme.Space.m) {
            Artwork(media: media, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("no \(player.name)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.accentText)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(track.artist)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                ProgressRow(track: track)
                    .padding(.top, Theme.Space.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Controls(media: media, track: track, small: 28, main: 36)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity)
    }

    // MARK: Large

    private func large(_ track: NowPlayingTrack, player: MediaPlayer) -> some View {
        HStack(spacing: Theme.Space.xl + Theme.Space.s) {
            Artwork(media: media, size: 160, glow: true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Tocando no \(player.name)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.accentText)
                    .padding(.bottom, Theme.Space.xs)
                Text(track.title)
                    .font(Theme.Font.greeting)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(track.artist)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if !track.album.isEmpty {
                    Text(track.album)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                ProgressRow(track: track)
                    .padding(.top, Theme.Space.l)
                Controls(media: media, track: track, small: 36, main: 52)
                    .padding(.top, Theme.Space.s)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.xl + Theme.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Artwork: View {
    @ObservedObject var media: NowPlayingService
    let size: CGFloat
    var glow = false

    private var radius: CGFloat { size > 100 ? Theme.Radius.card : Theme.Radius.artwork }

    var body: some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .background {
                        if glow {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: size, height: size)
                                .blur(radius: 28)
                                .opacity(0.45)
                        }
                    }
            } else if media.artworkLoading {
                Skeleton(cornerRadius: radius)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surfaceHi)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.32, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
            }
        }
        .frame(width: size, height: size)
    }
}

private struct ProgressRow: View {
    let track: NowPlayingTrack

    private var fraction: CGFloat {
        track.duration > 0 ? CGFloat(track.position / track.duration) : 0
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceHi)
                    Capsule().fill(Theme.accent).frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
            HStack {
                Text(Self.clock(track.position))
                Spacer()
                Text("-" + Self.clock(max(0, track.duration - track.position)))
            }
            .font(Theme.Font.captionMono)
            .foregroundStyle(Theme.textTertiary)
        }
        .animation(.linear(duration: 1), value: track.position)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct Controls: View {
    @ObservedObject var media: NowPlayingService
    let track: NowPlayingTrack
    let small: CGFloat
    let main: CGFloat

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            Button { media.previous() } label: { Image(systemName: "backward.fill") }
                .buttonStyle(CircleButtonStyle(size: small))
                .help("Anterior")
            Button { media.playPause() } label: {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                    .offset(x: track.isPlaying ? 0 : main * 0.03)
            }
            .buttonStyle(CircleButtonStyle(kind: .filled, size: main))
            .help(track.isPlaying ? "Pausar" : "Tocar")
            Button { media.next() } label: { Image(systemName: "forward.fill") }
                .buttonStyle(CircleButtonStyle(size: small))
                .help("Próxima")
        }
    }
}
