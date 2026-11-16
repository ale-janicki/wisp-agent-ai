import AppKit
import Combine
import os
import WispCore

enum MediaPlayer: CaseIterable, Sendable {
    case spotify, music

    var bundleId: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        }
    }

    var name: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Music"
        }
    }

    var changeNotification: Notification.Name {
        switch self {
        case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .music: Notification.Name("com.apple.Music.playerInfo")
        }
    }

    fileprivate var durationUnit: NowPlayingParser.DurationUnit {
        switch self {
        case .spotify: .milliseconds
        case .music: .seconds
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    fileprivate func guarded(_ body: String) -> String {
        """
        if application id "\(bundleId)" is running then
            tell application id "\(bundleId)"
                \(body)
            end tell
        end if
        return ""
        """
    }

    fileprivate var trackScript: String {
        let artwork = self == .spotify
            ? """
            set art to ""
            try
                set art to (artwork url of t) as text
            on error
                set art to ""
            end try
            """
            : "set art to \"\""
        return guarded("""
        set sep to character id 31
        set s to (player state as text)
        if s is "stopped" then return "stopped"
        set t to current track
        \(artwork)
        return s & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (player position as text) & sep & ((duration of t) as text) & sep & art
        """)
    }

    fileprivate var artworkDataScript: String? {
        guard self == .music else { return nil }
        return guarded("""
        if (count of artworks of current track) > 0 then return data of artwork 1 of current track
        """)
    }

    fileprivate func command(_ verb: String) -> String { guarded(verb) }
}

enum AutomationStatus: Sendable, Equatable {
    case granted, denied, notDetermined, notRunning
}

private enum AutomationCheck {
    private static let queue = DispatchQueue(label: "com.owner.wisp.automation", qos: .userInitiated)
    private static let requestQueue = DispatchQueue(label: "com.owner.wisp.automation.request", qos: .userInitiated)

    static func status(of player: MediaPlayer, ask: Bool) async -> AutomationStatus {
        let bundleId = player.bundleId
        let queue = ask ? requestQueue : queue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: determine(bundleId: bundleId, ask: ask))
            }
        }
    }

    private static func determine(bundleId: String, ask: Bool) -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let address = target.aeDesc else { return .notDetermined }
        let status = AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch Int(status) {
        case Int(noErr): return .granted
        case errAEEventNotPermitted: return .denied
        case errAEEventWouldRequireUserConsent: return .notDetermined
        case procNotFound: return .notRunning
        default: return .notDetermined
        }
    }
}

private struct ScriptOutput: Sendable {
    var text: String?
    var data: Data?
    var errorCode: Int?
}

private enum AppleScriptRunner {
    private static let queue = DispatchQueue(label: "com.owner.wisp.applescript", qos: .userInitiated)
    private static let requestQueue = DispatchQueue(label: "com.owner.wisp.applescript.request", qos: .userInitiated)

    static func run(_ source: String, prompting: Bool = false) async -> ScriptOutput {
        let queue = prompting ? requestQueue : queue
        return await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
                    continuation.resume(returning: ScriptOutput(errorCode: code))
                } else {
                    continuation.resume(returning: ScriptOutput(text: descriptor?.stringValue, data: descriptor?.data))
                }
            }
        }
    }
}

@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var player: MediaPlayer?
    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkLoading = false
    @Published private(set) var deniedPlayer: MediaPlayer?
    @Published private(set) var automation: [MediaPlayer: AutomationStatus] = [:]
    @Published private(set) var requesting: MediaPlayer?
    @Published private(set) var runningPlayer: MediaPlayer?

    var panelOpen = false {
        didSet {
            guard panelOpen != oldValue else { return }
            if panelOpen { refresh() }
            updateTicker()
        }
    }

    var isPlaying: Bool { track?.isPlaying == true }

    func automationStatus(for player: MediaPlayer) -> AutomationStatus {
        guard player.isRunning else { return .notRunning }
        return automation[player] ?? .notDetermined
    }

    var playerNeedingPermission: MediaPlayer? {
        MediaPlayer.allCases.first { $0.isRunning && automationStatus(for: $0) != .granted }
    }

    private let log = Logger(subsystem: "com.owner.wisp", category: "media")
    private var observers: [NSObjectProtocol] = []
    private var querying = false
    private var refreshAgain = false
    private var ticker: Task<Void, Never>?
    private var artworkKey: String?
    private var artworkFailure: (key: String, at: Date)?

    private static let artworkRetryDelay: TimeInterval = 30

    private static let permissionErrors: Set<Int> = [-1743, -1744]

    func start() {
        let distributed = DistributedNotificationCenter.default()
        for player in MediaPlayer.allCases {
            observers.append(distributed.addObserver(forName: player.changeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let id = app?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard MediaPlayer.allCases.contains(where: { $0.bundleId == id }) else { return }
                    self?.refresh()
                }
            })
        }
    }

    func refresh() {
        guard !querying else {
            refreshAgain = true
            return
        }
        let running = MediaPlayer.allCases.filter(\.isRunning)
        guard !running.isEmpty else {
            automation = Dictionary(uniqueKeysWithValues: MediaPlayer.allCases.map { ($0, .notRunning) })
            apply([], running: [])
            return
        }
        querying = true
        let known = automation
        Task { [weak self] in
            var statuses: [MediaPlayer: AutomationStatus] = [:]
            for player in MediaPlayer.allCases {
                if !running.contains(player) {
                    statuses[player] = .notRunning
                } else if known[player] == .granted {
                    statuses[player] = .granted
                } else {
                    statuses[player] = await AutomationCheck.status(of: player, ask: false)
                }
            }
            var results: [(MediaPlayer, ScriptOutput)] = []
            for player in running where statuses[player] == .granted {
                results.append((player, await AppleScriptRunner.run(player.trackScript)))
            }
            guard let self else { return }
            self.querying = false
            if self.automation != statuses { self.automation = statuses }
            self.apply(results, running: running)
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    func requestAutomation(for player: MediaPlayer) {
        guard requesting == nil else { return }
        guard player.isRunning else {
            automation[player] = .notRunning
            return
        }
        requesting = player
        Task { [weak self] in
            var status = await AutomationCheck.status(of: player, ask: true)
            if status == .notDetermined, player.isRunning {
                _ = await AppleScriptRunner.run(player.guarded("return name"), prompting: true)
                status = await AutomationCheck.status(of: player, ask: false)
            }
            guard let self else { return }
            self.automation[player] = status
            self.requesting = nil
            self.log.info("automation \(player.name, privacy: .public) after request: \(String(describing: status), privacy: .public)")
            self.refresh()
        }
    }

    func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    func previous() { send("previous track") }
    func playPause() { send("playpause") }
    func next() { send("next track") }

    private func send(_ verb: String) {
        guard let player, player.isRunning else { return }
        Task { [weak self] in
            let output = await AppleScriptRunner.run(player.command(verb))
            if let code = output.errorCode { self?.log.error("media \(verb, privacy: .public) failed: \(code)") }
            self?.refresh()
        }
    }

    private func apply(_ results: [(MediaPlayer, ScriptOutput)], running: [MediaPlayer]) {
        var tracks: [(MediaPlayer, NowPlayingTrack)] = []
        var denied: MediaPlayer?
        for (player, output) in results {
            if let code = output.errorCode {
                if Self.permissionErrors.contains(code) {
                    denied = denied ?? player
                    automation[player] = code == -1743 ? .denied : .notDetermined
                }
                log.error("now playing \(player.name, privacy: .public) failed: \(code)")
                continue
            }
            if let track = output.text.flatMap({ NowPlayingParser.parse($0, durationUnit: player.durationUnit) }) {
                tracks.append((player, track))
            }
        }
        let chosen = tracks.first { $0.1.isPlaying } ?? tracks.first
        runningPlayer = chosen?.0 ?? running.first
        denied = denied ?? running.first { automation[$0] == .denied }
        deniedPlayer = chosen == nil ? denied : nil
        if player != chosen?.0 { player = chosen?.0 }
        if track != chosen?.1 { track = chosen?.1 }
        loadArtwork()
        updateTicker()
    }

    // MARK: Artwork

    private func loadArtwork() {
        guard let player, let track else {
            artworkKey = nil
            artwork = nil
            artworkLoading = false
            return
        }
        let key = "\(player.bundleId)|\(track.title)|\(track.artist)|\(track.album)|\(track.artworkURL?.absoluteString ?? "")"
        guard key != artworkKey else { return }
        if let failure = artworkFailure, failure.key == key, Date().timeIntervalSince(failure.at) < Self.artworkRetryDelay {
            return
        }
        artworkKey = key
        artwork = nil

        let cacheKey = player.artworkDataScript == nil ? track.artworkURL?.absoluteString : key
        if let cacheKey, let cached = ArtworkCache.shared.cached(key: cacheKey) {
            artwork = cached
            artworkLoading = false
            return
        }
        artworkLoading = true
        Task { [weak self] in
            let image = await Self.fetchArtwork(player: player, url: track.artworkURL)
            if let image, player.artworkDataScript != nil { ArtworkCache.shared.store(image, key: key) }
            guard let self, self.artworkKey == key else { return }
            if image == nil {
                self.artworkFailure = (key, Date())
                self.artworkKey = nil
            } else {
                self.artworkFailure = nil
            }
            self.artwork = image
            self.artworkLoading = false
        }
    }

    private static func fetchArtwork(player: MediaPlayer, url: URL?) async -> NSImage? {
        if let script = player.artworkDataScript {
            let output = await AppleScriptRunner.run(script)
            return output.data.flatMap(NSImage.init(data:))
        }
        guard let url else { return nil }
        return await ArtworkCache.shared.image(for: url)
    }

    // MARK: Position

    private func updateTicker() {
        let shouldTick = panelOpen && isPlaying
        if shouldTick, ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.refresh()
                }
            }
        } else if !shouldTick {
            ticker?.cancel()
            ticker = nil
        }
    }
}
