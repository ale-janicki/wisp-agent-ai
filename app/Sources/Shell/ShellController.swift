import AppKit
import Combine
import os
import SwiftUI
import WispCore

enum StatusColor: Sendable {
    case ok, busy, error
}

@MainActor
final class ShellController: ObservableObject {
    @Published var state: PillState = .rest
    @Published var pillText: String?
    @Published var statusColor: StatusColor = .ok
    @Published private(set) var restHasNotch = false
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var pillBand: CGSize = .zero
    @Published var tab: PanelTab = .home

    var restTarget: () -> PillState = { .rest }

    private let log = Logger(subsystem: AppIdentity.bundleID, category: "shell")
    let conversation = ConversationViewModel()
    let media = NowPlayingService()
    let clipboard = ClipboardService()
    let notices = NoticeCenter()
    let meetings = MeetingRecordingModel()
    private let panel = NotchPanel()
    private var anchorDisplayID: CGDirectDisplayID?
    private var openedByHover = false
    private var dwellTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var hotKey: HotKey?
    private var screenObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    private var keepsNoticeFrame = false

    private static let dwell: Duration = .milliseconds(300)
    private static let animationDuration: TimeInterval = 0.25
    private static let foldDuration: Duration = .milliseconds(400)

    init() {
        let host = FirstMouseHostingView(rootView: PillView(controller: self))
        host.sizingOptions = []
        host.hitShape = { [weak self] size in self?.pillHitPath(in: size) }
        panel.contentView = host
        conversation.shell = self
        notices.shell = self
        notices.onChange = { [weak self] in self?.noticesChanged() }
        panel.onInactiveMouseDown = { [weak self] in
            guard let self, self.state == .panel else { return }
            self.openedByHover = false
            self.takeKey()
        }
    }

    // MARK: Notices

    var presentsNotice: Bool { state != .panel && notices.current != nil }
    var pillExpanded: Bool { presentsNotice || state == .active }
    var pillDrop: CGSize {
        presentsNotice ? NotchGeometry.noticeSize : CGSize(width: NotchGeometry.activeWidth, height: NotchGeometry.stripHeight)
    }
    var pillRadius: CGFloat { presentsNotice ? Theme.Radius.card : Theme.Radius.pill }

    private func noticesChanged() {
        if presentsNotice {
            if keepsNoticeFrame {
                updateMouseTransparency()
            } else {
                apply(animated: false, reason: "notice")
            }
        } else if keepsNoticeFrame {
            shrinkTask?.cancel()
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: NoticeMotion.settle)
                guard !Task.isCancelled, let self else { return }
                self.apply(animated: false, reason: "notice folded")
            }
        }
    }

    func open(_ target: NoticeTarget) {
        let model = conversation
        switch target {
        case .conversation(let id):
            model.openConversation(id: id)
            tab = .conversation
        case .topic(let thread):
            if model.linkedThread != thread {
                if let entry = model.sections.telegram.first(where: { $0.topic.thread == thread }) {
                    model.open(entry)
                }
            }
            tab = .conversation
        case .reminders:
            tab = PanelTab.reminders.isAvailable(in: model.profile) ? .reminders : .home
        case .update:
            UpdateModel.shared.showUpdate()
            return
        }
        pillClicked()
    }

    private func pillHitPath(in size: CGSize) -> CGPath? {
        guard state != .panel else { return nil }
        let drop = pillDrop
        let width = max(drop.width, pillBand.width)
        let rect = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: pillBand.height + drop.height)
        let shape = PillShape(band: pillBand, drop: drop, progress: pillExpanded ? 1 : 0, radius: pillRadius)
        return shape.path(in: rect).cgPath
    }

    private func updateMouseTransparency() {
        guard state != .panel else {
            panel.ignoresMouseEvents = false
            return
        }
        let frame = panel.frame
        let p = NSEvent.mouseLocation
        let local = CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y)
        let overPill = pillHitPath(in: frame.size)?.contains(local) ?? true
        panel.ignoresMouseEvents = !overPill
        if presentsNotice { notices.hover(overPill) }
    }

    func start() {
        installMonitors()
        hotKey = HotKey { [weak self] in self?.toggle() }
        if hotKey == nil { log.error("hotkey registration failed") }
        media.start()
        clipboard.start()
        notices.start()
        MeetingsCoordinator.shared.start(shell: self)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanchor() }
        }
        show(.rest)
    }

    // MARK: State

    func show(_ new: PillState) {
        let previous = state
        switch new {
        case .panel: anchorDisplayID = Self.screenUnderMouse().flatMap(Self.displayID(of:))
        case .rest, .active: anchorDisplayID = Self.restScreen().flatMap(Self.displayID(of:))
        }
        dwellTask?.cancel()
        dwellTask = nil
        if new != .panel { openedByHover = false }
        if previous == .panel, new != .panel {
            releaseKey()
            MemoryGraphModel.shared.panelClosed()
        }
        state = new
        media.panelOpen = new == .panel
        panel.hasShadow = new == .panel
        let reason = "state \(previous)->\(new)"
        if previous == .active, new == .rest, panel.isVisible {
            shrinkTask?.cancel()
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: Self.foldDuration)
                guard !Task.isCancelled, let self, self.state == .rest else { return }
                self.apply(animated: false, reason: "\(reason) folded")
            }
        } else {
            let pillOnly = previous != .panel && new != .panel
            apply(animated: panel.isVisible && previous != new && !pillOnly, reason: reason)
        }
        if new == .panel, !openedByHover { takeKey() }
    }

    private func takeKey() {
        if !panel.isKeyWindow {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        }
        panel.allowsKey = true
        panel.makeKey()
    }

    private func releaseKey() {
        panel.allowsKey = false
        defer { previousApp = nil }
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        let front = NSWorkspace.shared.frontmostApplication
        if let previousApp,
           front == nil || front?.bundleIdentifier == Bundle.main.bundleIdentifier || front == previousApp {
            previousApp.activate()
        }
        log.info("released key; restored=\(self.previousApp?.bundleIdentifier ?? "nil", privacy: .public) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public)")
    }

    func toggle() {
        openedByHover = false
        show(state == .panel ? restTarget() : .panel)
    }

    func pillClicked() {
        openedByHover = false
        if state != .panel { show(.panel) } else { takeKey() }
    }

    private func reanchor() {
        let screen: NSScreen?
        if state == .panel {
            screen = Self.screens().first { Self.displayID(of: $0) == anchorDisplayID } ?? Self.screenUnderMouse()
        } else {
            screen = Self.restScreen()
        }
        guard let screen else { return }
        anchorDisplayID = Self.displayID(of: screen)
        apply(animated: false, reason: "reanchor")
    }

    // MARK: Frame

    private var anchorScreen: NSScreen? {
        Self.screens().first { Self.displayID(of: $0) == anchorDisplayID } ?? Self.restScreen()
    }

    private func frame(for state: PillState, on screen: NSScreen) -> CGRect {
        NotchGeometry.frame(for: state, screen: screen.frame, notch: Self.notchRect(of: screen))
    }

    private func windowFrame(on screen: NSScreen) -> CGRect {
        guard state != .panel, keepsNoticeFrame else { return frame(for: state, on: screen) }
        return NotchGeometry.noticeFrame(screen: screen.frame, notch: Self.notchRect(of: screen))
    }

    private func apply(animated: Bool, reason: String) {
        guard let screen = anchorScreen else { return }
        shrinkTask?.cancel()
        shrinkTask = nil
        keepsNoticeFrame = presentsNotice
        let target = windowFrame(on: screen)
        let notch = Self.notchRect(of: screen)
        restHasNotch = notch != nil
        notchWidth = notch?.width ?? 0
        pillBand = NotchGeometry.topBand(screen: screen.frame, notch: notch).size
        let sameScreen = panel.screen.flatMap(Self.displayID(of:)) == Self.displayID(of: screen)
        var delta = ""
        if state == .rest, !keepsNoticeFrame, let notch {
            let expected = notch.insetBy(dx: -36, dy: 0)
            let d = max(
                abs(target.minX - expected.minX), abs(target.minY - expected.minY),
                abs(target.width - expected.width), abs(target.height - expected.height)
            )
            delta = " restVsNotchInsetDelta=\(d)"
        }
        log.info("""
        \(reason, privacy: .public) screen=\(NSStringFromRect(screen.frame), privacy: .public) \
        notch=\(notch.map { NSStringFromRect($0) } ?? "nil", privacy: .public) \
        window=\(NSStringFromRect(target), privacy: .public) \
        level=\(self.panel.level.rawValue)\(delta, privacy: .public)
        """)

        if !panel.isVisible {
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
        } else if animated, sameScreen {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.animationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                panel.animator().setFrame(target, display: true)
            }
            panel.contentView?.frame = CGRect(origin: .zero, size: panel.frame.size)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }
        updateMouseTransparency()
        #if DEBUG
        frameLog("apply \(reason) target=\(NSStringFromRect(target)) notch=\(notch.map { NSStringFromRect($0) } ?? "nil")")
        #endif
    }

    // MARK: Screens

    private static func screens() -> [NSScreen] { NSScreen.screens }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func notchRect(of screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return CGRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height)
    }

    private static func restScreen() -> NSScreen? {
        screens().first { notchRect(of: $0) != nil } ?? NSScreen.main ?? screens().first
    }

    private static func screenUnderMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return screens().first { inclusiveContains($0.frame, p) } ?? restScreen()
    }

    private static func inclusiveContains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }

    // MARK: Input

    private func installMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state == .panel, !self.pinnedOpen else { return }
                    self.show(self.restTarget())
                }
            }
        ) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.keyCode == 53, self.state != .rest else { return false }
                self.show(self.state == .panel ? self.restTarget() : .rest)
                return true
            }
            return handled ? nil : event
        }) { monitors.append(m) }
    }

    private func restFrameContains(_ p: CGPoint) -> Bool {
        guard let screen = anchorScreen else { return false }
        return Self.inclusiveContains(frame(for: .rest, on: screen), p)
    }

    private func mouseMoved() {
        updateMouseTransparency()
        let p = NSEvent.mouseLocation
        switch state {
        case .rest:
            let inside = !presentsNotice && restFrameContains(p)
            if inside, dwellTask == nil {
                dwellTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.dwell)
                    guard !Task.isCancelled, let self else { return }
                    self.dwellTask = nil
                    let still = self.restFrameContains(NSEvent.mouseLocation)
                    guard still, self.state == .rest else { return }
                    self.openedByHover = true
                    self.show(.panel)
                }
            } else if !inside {
                dwellTask?.cancel()
                dwellTask = nil
            }
        case .panel:
            if openedByHover, !Self.inclusiveContains(panel.frame, p) { show(restTarget()) }
        case .active:
            break
        }
    }

    // MARK: Debug

    #if DEBUG || WISP_PERF
    private var pinnedOpen = false

    func openPanelFromArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-WispOpenPanel"), args.indices.contains(index + 1),
              let tab = PanelTab(rawValue: args[index + 1])
        else { return }
        pinnedOpen = true
        self.tab = tab
        show(.panel)
    }
    #else
    private var pinnedOpen: Bool { false }
    #endif

    #if DEBUG
    private func logFrontmost(_ label: String) {
        log.info("frontmost \(label, privacy: .public)=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public)")
    }

    func snapshotLayout() -> (rest: CGRect, active: CGRect, panel: CGRect, notch: CGRect?)? {
        guard let screen = Self.restScreen() else { return nil }
        return (
            frame(for: .rest, on: screen),
            frame(for: .active, on: screen),
            frame(for: .panel, on: screen),
            Self.notchRect(of: screen)
        )
    }

    func setSnapshotState(_ new: PillState, notch: CGRect?) {
        state = new
        restHasNotch = notch != nil
        notchWidth = notch?.width ?? 0
        pillBand = Self.restScreen().map { NotchGeometry.topBand(screen: $0.frame, notch: notch).size } ?? .zero
    }

    private var frameLogHandle: FileHandle?
    private var lastFrameLine = ""

    func frameLog(_ event: String) {
        guard let frameLogHandle else { return }
        let host = panel.contentView
        let line = "window=\(NSStringFromRect(panel.frame)) midX=\(panel.frame.midX) host=\(host.map { NSStringFromRect($0.frame) } ?? "nil") safe=\(host.map { "\($0.safeAreaInsets.top),\($0.safeAreaInsets.left),\($0.safeAreaInsets.bottom),\($0.safeAreaInsets.right)" } ?? "nil") parts=\(debugFrames.sorted { $0.key < $1.key }.map { "\($0.key):\(NSStringFromRect($0.value))" }.joined(separator: " ")) state=\(state)"
        if event == "sample", line == lastFrameLine { return }
        lastFrameLine = line
        let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        frameLogHandle.write(Data("\(stamp) \(event) \(line)\n".utf8))
    }

    private var debugFrames: [String: CGRect] = [:]

    func debugReport(_ name: String, _ rect: CGRect) {
        guard debugFrames[name] != rect else { return }
        debugFrames[name] = rect
        frameLog("geometry")
    }

    func runDebugArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-WispFrameLog"), args.indices.contains(index + 1) {
            let path = args[index + 1]
            FileManager.default.createFile(atPath: path, contents: nil)
            frameLogHandle = FileHandle(forWritingAtPath: path)
            frameLog("start")
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.frameLog("sample") }
            }
        }
        conversation.runDemo(arguments: args)
        if args.contains("-WispGraphBench") {
            Task { await MemoryGraphBench.run(self) }
        }
        if args.contains("-WispDemoActive") {
            pillText = "\(conversation.personaName) pensando..."
            show(.active)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.show(.rest)
            }
        }
        if args.contains("-WispDemoNotice") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                for notice in NoticeCenter.samples(persona: self.conversation.personaName) { self.notices.post(notice) }
            }
        }
        if args.contains("-WispDemoToggle") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.logFrontmost("before open")
                self?.toggle()
                try? await Task.sleep(for: .seconds(2))
                self?.toggle()
                try? await Task.sleep(for: .milliseconds(500))
                self?.logFrontmost("after close")
            }
        }
        if args.contains("-WispDemoReanchor") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(7))
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
                _ = self
            }
        }
    }
    #endif
}
