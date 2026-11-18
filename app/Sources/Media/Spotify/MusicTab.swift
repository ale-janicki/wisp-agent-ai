import AppKit
import SwiftUI
import WispCore

struct MusicTab: View {
    @ObservedObject var media: NowPlayingService
    var openSettings: () -> Void
    private let spotify = SpotifyModel.shared

    var body: some View {
        VStack(spacing: Theme.Layout.cardGap) {
            MediaCardView(media: media, style: .compact)
            SpotifyPane(media: media, spotify: spotify, openSettings: openSettings)
        }
        .padding(.top, Theme.Space.xs)
        .onAppear { spotify.bootstrap() }
    }

    #if DEBUG
    static var snapshotShowsSteps = false
    #endif
}

private struct SpotifyPane: View {
    @ObservedObject var media: NowPlayingService
    let spotify: SpotifyModel
    var openSettings: () -> Void
    @State private var query = ""

    private var trailing: String? {
        guard spotify.auth == .signedIn, spotify.openPlaylist == nil, query.isEmpty,
              case .loaded(let lists) = spotify.playlists, !lists.isEmpty
        else { return nil }
        return lists.count == 1 ? "1 playlist" : "\(lists.count) playlists"
    }

    var body: some View {
        TabCard(title: "Spotify", icon: "music.note.list", trailing: trailing) {
            switch spotify.auth {
            case .unknown:
                SkeletonRows(count: 3)
            case .signedOut, .signingIn:
                ConnectSection(spotify: spotify, openSettings: openSettings)
            case .signedIn:
                signedIn
            }
        }
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SearchField(text: $query, placeholder: "Buscar no Spotify")
            if let notice = spotify.notice {
                if notice.isError {
                    InlineError(text: notice.text)
                } else {
                    HStack(spacing: Theme.Space.s) {
                        Circle().fill(Theme.ok).frame(width: 6, height: 6)
                        Text(notice.text)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.leading, Theme.Space.m)
                }
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchResultsList(media: media, spotify: spotify, query: query) { playlist in
                    query = ""
                    spotify.open(playlist)
                }
            } else if let playlist = spotify.openPlaylist {
                PlaylistDetail(media: media, spotify: spotify, playlist: playlist)
            } else {
                PlaylistGrid(media: media, spotify: spotify)
            }
        }
        .task(id: query) { await spotify.search(query) }
    }
}

// MARK: Not connected

private struct ConnectSection: View {
    let spotify: SpotifyModel
    var openSettings: () -> Void
    @State private var showsSteps = ConnectSection.initialSteps

    private static var initialSteps: Bool {
        #if DEBUG
        return MusicTab.snapshotShowsSteps
        #else
        return false
        #endif
    }

    private var signingIn: Bool { spotify.auth == .signingIn }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Button {
                    if spotify.hasClientID {
                        spotify.connect()
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) { showsSteps.toggle() }
                    }
                } label: {
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: "link")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 30, height: 30)
                            .background(Theme.accentFill, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(signingIn ? "Conectando ao Spotify…" : "Conectar Spotify")
                                .font(Theme.Font.bodyMedium)
                                .foregroundStyle(Theme.textPrimary)
                            Text(subtitle)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Theme.Space.s)
                        if signingIn {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: spotify.hasClientID ? "arrow.up.right" : (showsSteps ? "chevron.up" : "chevron.down"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .buttonStyle(RowButtonStyle(height: 48))
                .disabled(signingIn)
                if signingIn {
                    Button("Cancelar") { spotify.cancelConnect() }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            }
            if let error = spotify.authError {
                InlineError(text: error)
            }
            if !spotify.hasClientID && showsSteps {
                SpotifySetupSteps(openSettings: openSettings)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.xs)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        if signingIn { return "Termine o login no navegador; o Wisp espera até 5 minutos." }
        if spotify.hasClientID { return "Suas playlists, busca e fila, tocando no seu Spotify." }
        return "Antes, crie seu app no Spotify em 4 passos."
    }
}

struct SpotifySetupSteps: View {
    var openSettings: (() -> Void)?
    @State private var copied = false

    private static let dashboard = URL(string: "https://developer.spotify.com/dashboard")!

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            step(1, "Em developer.spotify.com/dashboard, clique em Create app e dê um nome (ex.: Wisp).") {
                Button("Abrir painel") { NSWorkspace.shared.open(Self.dashboard) }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
            step(2, "Em Redirect URIs, adicione exatamente este endereço:") {
                HStack(spacing: Theme.Space.s) {
                    Text(SpotifyAuth.redirectURI.absoluteString)
                        .font(Theme.Font.tool)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Theme.surfaceHi, in: Capsule())
                    Button(copied ? "Copiado" : "Copiar") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SpotifyAuth.redirectURI.absoluteString, forType: .string)
                        copied = true
                    }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            }
            step(3, "Em APIs used, marque Web API e salve.") { EmptyView() }
            step(4, "Copie o Client ID do app e cole em Ajustes > Integrações.") {
                if let openSettings {
                    Button("Abrir Ajustes", action: openSettings)
                        .buttonStyle(CapsuleButtonStyle(kind: .accent))
                }
            }
            Text("Apps novos ficam em modo de desenvolvimento: exigem Spotify Premium do dono e liberam até 5 contas em Users Management.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ number: Int, _ text: String, @ViewBuilder accessory: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text("\(number)")
                .font(Theme.Font.captionMono)
                .foregroundStyle(Theme.accentText)
                .frame(width: 18, height: 18)
                .background(Theme.accentFill, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
    }
}

// MARK: Playlists

private struct PlaylistGrid: View {
    @ObservedObject var media: NowPlayingService
    let spotify: SpotifyModel

    private static let minTile: CGFloat = 104
    private static let inset: CGFloat = 12
    @State private var width: CGFloat = 0

    /// Columns that fill the whole row: as many as fit at the minimum size, then each grows to share the width.
    private var layout: (columns: [GridItem], tile: CGFloat) {
        let gap = Theme.Space.m
        let cell = Self.minTile + Self.inset
        let count = max(1, Int((width + gap) / (cell + gap)))
        let slot = width > 0 ? (width - CGFloat(count - 1) * gap) / CGFloat(count) : cell
        return (Array(repeating: GridItem(.fixed(slot), spacing: gap, alignment: .top), count: count), max(Self.minTile, slot - Self.inset))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @ViewBuilder private var content: some View {
        switch spotify.playlists {
        case .idle, .loading:
            VStack(alignment: .leading, spacing: 2) {
                SectionCaption(text: "Suas playlists")
                LazyVGrid(columns: layout.columns, alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(0..<5, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            Skeleton(cornerRadius: Theme.Radius.artwork).frame(width: layout.tile, height: layout.tile)
                            Skeleton(cornerRadius: 4).frame(width: 72, height: 10)
                        }
                        .padding(6)
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                InlineError(text: message)
                Button("Tentar de novo") { spotify.loadPlaylists() }
                    .buttonStyle(CapsuleButtonStyle(kind: .ghost))
            }
        case .loaded(let playlists) where playlists.isEmpty:
            TabMessage(text: "Você ainda não tem playlists no Spotify")
        case .loaded(let playlists):
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SectionCaption(text: "Suas playlists")
                    LazyVGrid(columns: layout.columns, alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(playlists) { playlist in
                            PlaylistTile(playlist: playlist, size: layout.tile, busy: spotify.busyURI == playlist.uri) {
                                spotify.open(playlist)
                            } play: {
                                spotify.play(.context(playlist.uri), key: playlist.uri, media: media)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct PlaylistTile: View {
    let playlist: SpotifyPlaylist
    let size: CGFloat
    let busy: Bool
    let open: () -> Void
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                RemoteArtwork(url: playlist.images.best(forPixels: Int(size * 2)), size: size, placeholder: "music.note.list")
                    .overlay(alignment: .bottomTrailing) {
                        if busy {
                            ProgressView().controlSize(.small).padding(6)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(SpotifyFormat.count(playlist.trackCount))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                .frame(width: size, alignment: .leading)
            }
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous)
                    .fill(hovering ? Theme.surfaceHi.opacity(0.7) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(playlist.name)
        .contextMenu {
            Button("Tocar playlist", action: play)
            Button("Abrir", action: open)
        }
    }
}

private struct PlaylistDetail: View {
    @ObservedObject var media: NowPlayingService
    let spotify: SpotifyModel
    let playlist: SpotifyPlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Button { spotify.closePlaylist() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(CircleButtonStyle(size: 26))
                    .help("Voltar às playlists")
                RemoteArtwork(url: playlist.images.best(forPixels: 80), size: 40, placeholder: "music.note.list")
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text([SpotifyFormat.count(playlist.trackCount), playlist.ownerName].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                Button {
                    spotify.play(.context(playlist.uri), key: playlist.uri, media: media)
                } label: {
                    HStack(spacing: 6) {
                        if spotify.busyURI == playlist.uri {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Tocar")
                    }
                }
                .buttonStyle(CapsuleButtonStyle(kind: .accent))
                .disabled(spotify.busyURI != nil)
            }
            switch spotify.playlistTracks {
            case .idle, .loading:
                SkeletonRows(count: 5)
            case .failed(let message):
                TabMessage(text: message)
            case .loaded(let tracks) where tracks.isEmpty:
                TabMessage(text: "Esta playlist está vazia")
            case .loaded(let tracks):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(tracks) { track in
                            TrackRow(track: track, spotify: spotify) {
                                spotify.play(.context(playlist.uri, startAt: track.uri), key: track.uri, media: media)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

// MARK: Search

private struct SearchResultsList: View {
    @ObservedObject var media: NowPlayingService
    let spotify: SpotifyModel
    let query: String
    let openPlaylist: (SpotifyPlaylist) -> Void

    var body: some View {
        switch spotify.results {
        case .idle, .loading:
            SkeletonRows(count: 5)
        case .failed(let message):
            InlineError(text: message)
        case .loaded(let results) where results.isEmpty:
            TabMessage(text: "Nada no Spotify para “\(query)”")
        case .loaded(let results):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !results.tracks.isEmpty {
                        SectionCaption(text: "Músicas")
                        ForEach(results.tracks) { track in
                            TrackRow(track: track, spotify: spotify) {
                                spotify.play(.tracks([track.uri]), key: track.uri, media: media)
                            }
                        }
                    }
                    if !results.albums.isEmpty {
                        SectionCaption(text: "Álbuns")
                        ForEach(results.albums) { album in
                            ItemRow(
                                artwork: album.images.best(forPixels: 64),
                                title: album.name,
                                subtitle: ["Álbum", album.artistLine].filter { !$0.isEmpty }.joined(separator: " · "),
                                busy: spotify.busyURI == album.uri,
                                placeholder: "square.stack"
                            ) {
                                spotify.play(.context(album.uri), key: album.uri, media: media)
                            }
                            .contextMenu {
                                Button("Tocar álbum") { spotify.play(.context(album.uri), key: album.uri, media: media) }
                            }
                        }
                    }
                    if !results.playlists.isEmpty {
                        SectionCaption(text: "Playlists")
                        ForEach(results.playlists) { playlist in
                            ItemRow(
                                artwork: playlist.images.best(forPixels: 64),
                                title: playlist.name,
                                subtitle: ["Playlist", playlist.ownerName].compactMap { $0 }.joined(separator: " · "),
                                busy: spotify.busyURI == playlist.uri,
                                placeholder: "music.note.list"
                            ) {
                                openPlaylist(playlist)
                            }
                            .contextMenu {
                                Button("Tocar playlist") { spotify.play(.context(playlist.uri), key: playlist.uri, media: media) }
                            }
                        }
                    }
                    if !results.artists.isEmpty {
                        SectionCaption(text: "Artistas")
                        ForEach(results.artists) { artist in
                            ItemRow(
                                artwork: artist.images.best(forPixels: 64),
                                title: artist.name,
                                subtitle: "Artista",
                                busy: spotify.busyURI == artist.uri,
                                placeholder: "person.fill",
                                round: true
                            ) {
                                spotify.play(.context(artist.uri), key: artist.uri, media: media)
                            }
                            .contextMenu {
                                Button("Tocar artista") { spotify.play(.context(artist.uri), key: artist.uri, media: media) }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: Rows

private struct TrackRow: View {
    let track: SpotifyTrack
    let spotify: SpotifyModel
    let play: () -> Void

    var body: some View {
        ItemRow(
            artwork: track.artwork.best(forPixels: 64),
            title: track.name,
            subtitle: track.artistLine,
            trailing: SpotifyFormat.duration(ms: track.durationMs),
            busy: spotify.busyURI == track.uri,
            action: play
        )
        .contextMenu {
            Button("Tocar", action: play)
            Button("Adicionar à fila") { spotify.enqueue(track) }
        }
    }
}

private struct ItemRow: View {
    let artwork: URL?
    let title: String
    let subtitle: String
    var trailing: String?
    var busy = false
    var placeholder = "music.note"
    var round = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                RemoteArtwork(url: artwork, size: 32, radius: round ? 16 : 6, placeholder: placeholder)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                if busy {
                    ProgressView().controlSize(.small)
                } else if let trailing {
                    Text(trailing)
                        .font(Theme.Font.captionMono)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(RowButtonStyle(height: 44))
        .help(subtitle.isEmpty ? title : "\(title) — \(subtitle)")
    }
}

enum SpotifyFormat {
    static func duration(ms: Int) -> String {
        let total = max(0, ms) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func count(_ tracks: Int?) -> String {
        guard let tracks else { return "Playlist" }
        return tracks == 1 ? "1 música" : "\(tracks) músicas"
    }
}

// MARK: Ajustes

struct SpotifySettingsCard: View {
    private let settings = AppSettings.shared
    private let spotify = SpotifyModel.shared
    var embedded = false
    @State private var draft = ""

    var body: some View {
        if embedded {
            content
                .onAppear(perform: load)
        } else {
            content
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .onAppear(perform: load)
        }
    }

    private func load() {
        draft = settings.settings.spotifyClientID
        spotify.bootstrap()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    if !embedded {
                        Text("Spotify")
                            .font(Theme.Font.title)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text(status)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if spotify.auth == .signedIn {
                    Button("Sair") { spotify.signOut() }
                        .buttonStyle(CapsuleButtonStyle(kind: .ghost))
                }
            }
            HStack(spacing: Theme.Space.m) {
                Text("Spotify Client ID")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 120, alignment: .leading)
                TextField("", text: $draft, prompt: Text("cole o Client ID do seu app").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.Font.tool)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.surfaceHi, in: Capsule())
                    .onSubmit { settings.setSpotifyClientID(draft) }
                    .onChange(of: draft) { _, text in settings.setSpotifyClientID(text) }
            }
            if !spotify.hasClientID {
                SpotifySetupSteps()
            }
        }
    }

    private var status: String {
        switch spotify.auth {
        case .signedIn: "Conectado. A sessão fica só no Keychain deste Mac."
        case .signingIn: "Conectando pelo navegador…"
        case .unknown, .signedOut: spotify.hasClientID ? "Conecte na aba Música." : "Crie seu app no Spotify e cole o Client ID aqui."
        }
    }
}
