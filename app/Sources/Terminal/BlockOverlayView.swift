import AppKit
import WispCore

/// The blocks drawn over the terminal's screen: a header above each command's prompt, a red border and tint on a failed one's body,
/// a highlight on the selected one. It sits above SwiftTerm's view with the same frame and lets every mouse event through except those on a
/// header or the border. Nothing here polls: it is redrawn when the engine says the screen moved (scroll, resize, output) or when the
/// blocks changed.
///
/// Alignment: SwiftTerm draws row `n` of the screen with its top at `n * cellHeight` from the view's top. `TerminalViewport` gives the
/// first row on screen as a scroll-invariant row number (the cell height from `getOptimalFrameSize`, the position from `scrollPosition`
/// and the snapshot's `liveTopRow`), and blocks are kept in the same numbering, so a block's y is `(row - top) * cellHeight`.
@MainActor
final class BlockOverlayView: NSView {
    private enum Action: CaseIterable {
        case copyCommand, copyOutput, rerun

        var title: String {
            switch self {
            case .copyCommand: "Copiar comando"
            case .copyOutput: "Copiar saída"
            case .rerun: "Colar de novo"
            }
        }
    }

    private struct Geometry {
        let block: TerminalBlock
        let header: NSRect?
        let body: NSRect
        let actions: [(action: Action, rect: NSRect)]
    }

    private weak var session: TerminalSession?
    private weak var engine: SwiftTermEngine?
    private var viewport: TerminalViewport?
    private var hovered: Int?
    private var reanchoring = false
    /// What "Colar de novo" did instead of typing (copied the command) or why it did nothing, in that block's header for a moment.
    private var notice: (block: Int, text: String, isError: Bool)?
    private let spinner = NSProgressIndicator()
    private static let gutter: CGFloat = 6

    /// The entries of the right-click menu; `tag` carries the case.
    private enum MenuEntry: Int {
        case command, output, both, top

        var title: String {
            switch self {
            case .command: "Copiar comando"
            case .output: "Copiar saída"
            case .both: "Copiar comando e saída"
            case .top: "Ir para o topo do bloco"
            }
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Wiring

    func attach(session: TerminalSession, engine: SwiftTermEngine) {
        if self.session !== session || self.engine !== engine { detach() }
        self.session = session
        self.engine = engine
        engine.onViewportChange = { [weak self] in self?.refresh() }
        session.onBlocksChanged = { [weak self] in self?.refresh() }
        refresh()
    }

    func detach() {
        engine?.onViewportChange = nil
        session?.onBlocksChanged = nil
        session = nil
        engine = nil
        viewport = nil
        spinner.stopAnimation(nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if session != nil { refresh() }
    }

    /// One read of where the screen is, then one redraw.
    func refresh() {
        guard let session, let engine else { return }
        viewport = engine.viewport()
        guard let viewport else {
            needsDisplay = true
            return
        }
        if !viewport.alternateScreen { session.trimBlocks(before: viewport.firstRetained) }
        if engine.reflowPending, !reanchoring { reanchor(engine: engine, session: session) }
        updateSpinner()
        needsDisplay = true
    }

    /// The width changed and the terminal reflowed its rows: every block is found again by its command text. Waits for the size to
    /// settle, reads the rows off the main thread, and draws nothing meanwhile (a stale header would sit on the wrong line).
    private func reanchor(engine: SwiftTermEngine, session: TerminalSession) {
        reanchoring = true
        let view = engine.view
        Task { [weak self] in
            repeat {
                engine.reflowHandled()
                try? await Task.sleep(for: .milliseconds(200))
            } while engine.reflowPending
            let snapshot = session.blocks.blocks
            let rows = await Task.detached { SwiftTermEngine.allRows(of: view) }.value
            let found = BlockText.reanchor(snapshot, rows: rows)
            // Commands may have ended or started while the rows were read: the tracker as it is now wins, only the rows move.
            session.replaceBlocks(BlockText.merge(reanchored: found, snapshot: snapshot, current: session.blocks.blocks))
            self?.reanchoring = false
            self?.refresh()
        }
    }

    private func updateSpinner() {
        guard let viewport, !reanchoring, !viewport.alternateScreen,
              let running = session?.blocks.running, running.promptRow - 1 >= viewport.top,
              running.promptRow - 1 < viewport.top + viewport.rows else {
            spinner.stopAnimation(nil)
            return
        }
        let side: CGFloat = 12
        let y = CGFloat(running.promptRow - 1 - viewport.top) * viewport.cellHeight + (viewport.cellHeight - side) / 2
        spinner.frame = NSRect(x: 7, y: y, width: side, height: side)
        spinner.startAnimation(nil)
    }

    // MARK: Geometry

    private func geometry() -> [Geometry] {
        guard let session, let viewport, !viewport.alternateScreen, !reanchoring else { return [] }
        let height = viewport.cellHeight
        let bottom = viewport.top + viewport.rows
        let idle = session.blocks.running == nil
        var result = [Geometry]()
        for block in session.blocks.blocks {
            let headRow = block.promptRow - 1
            let end = block.outputEnd ?? max(viewport.cursorRow + 1, block.outputStart)
            guard end > viewport.top, headRow < bottom else { continue }
            let headY = CGFloat(headRow - viewport.top) * height
            let body = NSRect(x: 0, y: headY, width: bounds.width, height: CGFloat(end - headRow) * height)
            let header = headRow >= viewport.top ? NSRect(x: 0, y: headY, width: bounds.width, height: height) : nil
            var actions = [(action: Action, rect: NSRect)]()
            if let header, hovered == block.id || session.selectedBlockID == block.id {
                var right = header.maxX - 6
                for action in Action.allCases.reversed() {
                    if action == .rerun, !(idle && !block.isRunning && !block.command.isEmpty) { continue }
                    if action == .copyOutput, block.isRunning { continue }
                    let width = Self.width(of: action.title) + 12
                    actions.append((action, NSRect(x: right - width, y: header.minY + 1, width: width, height: height - 2)))
                    right -= width + 4
                }
            }
            result.append(Geometry(block: block, header: header, body: body, actions: actions))
        }
        return result
    }

    private static let actionFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private static let commandFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let metaFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)

    private static func width(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: actionFont]).width)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let viewport else { return }
        let selected = session?.selectedBlockID
        for geo in geometry() {
            let block = geo.block
            let color = Self.color(for: block)
            // Only a failed block marks its body (red bar and a faint tint); a running or succeeded one shows its state in the header.
            if case .finished(let code) = block.status, code != 0 {
                NSColor(Theme.error).withAlphaComponent(0.07).setFill()
                geo.body.fill()
                let borderTop = max(geo.body.minY + viewport.cellHeight, 0)
                color.setFill()
                NSRect(x: 0, y: borderTop, width: 3, height: max(0, geo.body.maxY - borderTop)).fill()
            }
            if selected == block.id {
                NSColor(Theme.accent).withAlphaComponent(0.10).setFill()
                geo.body.fill()
            }
            if let header = geo.header { drawHeader(block, in: header, actions: geo.actions, selected: selected == block.id) }
        }
    }

    private func drawHeader(_ block: TerminalBlock, in rect: NSRect, actions: [(action: Action, rect: NSRect)], selected: Bool) {
        let bar = rect.insetBy(dx: 0, dy: 1)
        let path = NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4)
        (selected ? NSColor(Theme.accentFill) : NSColor(Theme.surface).withAlphaComponent(0.92)).setFill()
        path.fill()
        if case .finished(let code) = block.status, code != 0 {
            Self.color(for: block).setFill()
            NSRect(x: 0, y: bar.minY, width: 3, height: bar.height).fill()
        }

        var left = bar.minX + 8
        switch block.status {
        case .running:
            left += 18
        case .finished(0):
            left += Self.draw("✓", in: bar, x: left, font: Self.metaFont, color: NSColor(Theme.ok)) + 6
        case .finished(let code):
            left += Self.draw("✗ \(code)", in: bar, x: left, font: Self.metaFont, color: NSColor(Theme.error)) + 6
        case .lost:
            left += Self.draw("–", in: bar, x: left, font: Self.metaFont, color: NSColor(Theme.textTertiary)) + 6
        }

        var right = actions.last.map { $0.rect.minX - 6 } ?? bar.maxX - 8
        if let notice, notice.block == block.id {
            let width = min(ceil((notice.text as NSString).size(withAttributes: [.font: Self.metaFont]).width), max(0, right - left) * 0.7)
            right -= width
            Self.draw(notice.text, in: bar, x: right, width: width, font: Self.metaFont, color: NSColor(notice.isError ? Theme.error : Theme.accentText))
            right -= 10
        }
        var meta = [String]()
        if let directory = block.directory { meta.append((directory as NSString).lastPathComponent.isEmpty ? "/" : (directory as NSString).lastPathComponent) }
        if let duration = block.duration { meta.append(BlockDuration.text(duration)) }
        if !meta.isEmpty {
            let text = meta.joined(separator: " · ")
            let width = ceil((text as NSString).size(withAttributes: [.font: Self.metaFont]).width)
            right -= width
            Self.draw(text, in: bar, x: right, font: Self.metaFont, color: NSColor(Theme.textSecondary))
            right -= 10
        }
        let command = block.command.isEmpty ? "(sem comando)" : block.command.replacingOccurrences(of: "\n", with: " ⏎ ")
        Self.draw(command, in: bar, x: left, width: max(0, right - left), font: Self.commandFont, color: NSColor(Theme.textPrimary))

        for (action, rect) in actions {
            NSColor(Theme.accent).withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            Self.draw(action.title, in: rect, x: rect.minX + 6, font: Self.actionFont, color: NSColor(Theme.accentText))
        }
    }

    /// One line of text, vertically centered in `rect`, truncated at `width`. Returns the width it took.
    @discardableResult
    private static func draw(_ text: String, in rect: NSRect, x: CGFloat, width: CGFloat? = nil, font: NSFont, color: NSColor) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let natural = ceil((text as NSString).size(withAttributes: attributes).width)
        let used = min(natural, width ?? natural)
        let lineHeight = ceil(font.ascender - font.descender)
        let target = NSRect(x: x, y: rect.minY + (rect.height - lineHeight) / 2, width: used, height: lineHeight)
        (text as NSString).draw(with: target, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        return used
    }

    private static func color(for block: TerminalBlock) -> NSColor {
        switch block.status {
        case .running: NSColor(Theme.accent)
        case .finished(0): NSColor(Theme.ok)
        case .finished: NSColor(Theme.error)
        case .lost: NSColor(Theme.textTertiary)
        }
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // A right click (or Control-click) anywhere on a block is ours, for its menu; every other press in the body goes to the terminal.
        // A program that tracks the mouse keeps its right clicks.
        let programTracksMouse = engine.map { $0.view.currentMouseMode != .off } ?? false
        let contextClick = !programTracksMouse && (NSApp.currentEvent.map { $0.type == .rightMouseDown || ($0.type == .leftMouseDown && $0.modifierFlags.contains(.control)) } ?? false)
        for geo in geometry() {
            if let header = geo.header, header.contains(local) { return self }
            if local.x < Self.gutter, geo.body.contains(local) { return self }
            if contextClick, geo.body.contains(local) { return self }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let id = geometry().last { $0.body.contains(local) }?.block.id
        if id != hovered {
            hovered = id
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil {
            hovered = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let session else { return }
        let local = convert(event.locationInWindow, from: nil)
        guard let geo = geometry().last(where: { $0.body.contains(local) }) else { return }
        // The keyboard stays with the terminal, so ⌘C and the block shortcuts act on what was just clicked.
        if let view = engine?.view, window?.firstResponder !== view { window?.makeFirstResponder(view) }
        if let hit = geo.actions.first(where: { $0.rect.contains(local) }) {
            perform(hit.action, on: geo.block)
            return
        }
        session.selectBlock(session.selectedBlockID == geo.block.id ? nil : geo.block.id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        guard let block = geometry().last(where: { $0.body.contains(local) })?.block else { return nil }
        session?.selectBlock(block.id)
        if let view = engine?.view, window?.firstResponder !== view { window?.makeFirstResponder(view) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in [MenuEntry.command, .output, .both, .top] {
            let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = entry.rawValue
            item.representedObject = block.id
            item.isEnabled = !(block.isRunning && (entry == .output || entry == .both))
            switch entry {
            case .command:
                item.keyEquivalent = "c"
                item.keyEquivalentModifierMask = [.command, .shift]
            case .output:
                item.keyEquivalent = "c"
                item.keyEquivalentModifierMask = [.command, .shift, .option]
            case .both, .top:
                break
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let entry = MenuEntry(rawValue: sender.tag), let id = sender.representedObject as? Int,
              let block = session?.blocks.block(id: id) else { return }
        switch entry {
        case .command: copy(.command, of: block)
        case .output: copy(.output, of: block)
        case .both: copy(.commandAndOutput, of: block)
        case .top: engine?.scroll(toRow: block.promptRow - 1)
        }
    }

    // MARK: Actions

    private func perform(_ action: Action, on block: TerminalBlock) {
        switch action {
        case .copyCommand: copy(.command, of: block)
        case .copyOutput: copy(.output, of: block)
        case .rerun:
            switch session?.rerun(block.id) {
            case .success(.copy(let text)):
                Self.copy(text)
                show(BlockRerun.copiedNotice, on: block.id, isError: false, for: 3)
            case .failure(let refusal):
                show(refusal.message, on: block.id, isError: true, for: 4)
            case .success(.type), nil:
                break
            }
        }
    }

    private func show(_ text: String, on block: Int, isError: Bool, for seconds: Double) {
        notice = (block, text, isError)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.notice?.block == block, self.notice?.text == text else { return }
            self.notice = nil
            self.needsDisplay = true
        }
    }

    /// The selected block's command, output or both, for ⇧⌘C, ⌥⇧⌘C and ⌘C. False when nothing is selected or the part is not
    /// there yet (a running block has no output to copy).
    @discardableResult
    func copySelected(_ part: BlockCopy) -> Bool {
        guard let block = session?.blocks.block(id: session?.selectedBlockID), !(block.isRunning && part != .command) else { return false }
        copy(part, of: block)
        return true
    }

    private func copy(_ part: BlockCopy, of block: TerminalBlock) {
        var output = ""
        if part != .command, let engine {
            let end = block.outputEnd ?? block.outputStart
            output = BlockText.output(engine.rows(block.outputStart..<max(block.outputStart, end)))
        }
        Self.copy(part.text(command: block.command, output: output))
    }

    /// ⌘↑ and ⌘↓: select the block before or after and scroll to it. False when there is none, so the key goes on.
    @discardableResult
    func jump(previous: Bool) -> Bool {
        guard let session, let engine, let viewport = engine.viewport(), !viewport.alternateScreen else { return false }
        let target = previous
            ? session.blocks.previous(before: session.selectedBlockID, topRow: viewport.top)
            : session.blocks.next(after: session.selectedBlockID, bottomRow: viewport.top + viewport.rows - 1)
        guard let target else { return false }
        session.selectBlock(target.id)
        engine.scroll(toRow: target.promptRow - 1)
        return true
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
