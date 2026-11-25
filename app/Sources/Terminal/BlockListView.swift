import AppKit
import WispCore

@MainActor
final class BlockTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    var onBlankClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
    }

    override func mouseDown(with event: NSEvent) { onBlankClick?() }

    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

@MainActor
final class BlockListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct Seen: Equatable {
        var status: TerminalBlock.Status
        var command: String
        var prompt: [StyledLine]
        var output: BlockOutput?
    }

    private struct Height {
        var width: CGFloat
        var revision: Int
        var epoch: Int
        var body: CGFloat
        var total: CGFloat
    }

    private static let exactLimit = 1_500
    private static let sampleLines = 200
    private static let fallbackFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let scroll = NSScrollView()
    private let table = BlockTableView()
    private let findBar = BlockFindBar(frame: NSRect(origin: .zero, size: BlockFindBar.size))
    private lazy var measurer = BlockOutputTextView()

    private var blocks = [TerminalBlock]()
    private var order = [Int]()
    private var outputs = [Int: BlockOutput]()
    private var seen = [Int: Seen]()
    private var revisions = [Int: Int]()
    private var heights = [Int: Height]()
    private var epoch = 0
    private var font = BlockListView.fallbackFont
    private var colors: ThemeColors?
    private var measuredWidth: CGFloat = 0
    private var needsFullRemeasure = false
    private var selection = BlockSelection()

    private var followsBottom = true
    private var adjusting = false

    private var matches = [BlockMatch]()
    private var currentMatch: Int?
    private var highlights = [Int: BlockFindHighlight]()
    private var matchCache = [Int: (query: String, revision: Int, matches: [BlockMatch])]()

    var onRerun: ((String) -> Bool)?
    var onFocusEditor: ((NSEvent?) -> Void)?
    var onSelectionChange: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("block"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsColumnSelection = false
        table.focusRingType = .none
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.onKey = { [weak self] event in self?.routeKey(event) ?? false }
        table.onBlankClick = { [weak self] in self?.clearSelection() }
        scroll.documentView = table

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        findBar.isHidden = true
        findBar.onQueryChange = { [weak self] in self?.setQuery($0) }
        findBar.onNext = { [weak self] in self?.stepMatch(1) }
        findBar.onPrevious = { [weak self] in self?.stepMatch(-1) }
        findBar.onClose = { [weak self] in self?.closeFind() }
        addSubview(findBar)
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Scrolling

    private var clip: NSClipView { scroll.contentView }
    private var contentWidth: CGFloat { max(1, scroll.contentSize.width) }

    private var isAtBottom: Bool { clip.bounds.maxY >= table.frame.height - 4 }

    @objc private func clipScrolled() {
        if !adjusting { followsBottom = isAtBottom }
    }

    func scrollToBottom() {
        followsBottom = true
        scrollTo(y: table.frame.height)
    }

    private func scrollTo(y: CGFloat) {
        adjusting = true
        defer { adjusting = false }
        let limit = max(0, table.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), limit)))
        scroll.reflectScrolledClipView(clip)
    }

    private func reveal(row: Int) {
        let rect = table.rect(ofRow: row)
        let visible = clip.bounds
        var y = visible.minY
        if rect.minY < visible.minY || rect.height >= visible.height {
            y = rect.minY
        } else if rect.maxY > visible.maxY {
            y = rect.maxY - visible.height
        }
        followsBottom = false
        scrollTo(y: y)
        followsBottom = isAtBottom
    }

    override func layout() {
        super.layout()
        let width = contentWidth
        if abs(width - measuredWidth) > 0.5 {
            measuredWidth = width
            remeasure()
        }
        findBar.frame = NSRect(
            x: max(0, bounds.width - BlockFindBar.size.width - 16), y: 8, width: min(BlockFindBar.size.width, bounds.width - 16),
            height: BlockFindBar.size.height)
    }

    private func remeasure() {
        guard !blocks.isEmpty else { return }
        if window?.inLiveResize == true {
            let visible = table.rows(in: table.visibleRect)
            let first = max(0, visible.location - 8)
            let last = min(blocks.count, NSMaxRange(visible) + 8)
            if first < last { table.noteHeightOfRows(withIndexesChanged: IndexSet(first..<last)) }
            needsFullRemeasure = true
        } else {
            table.noteHeightOfRows(withIndexesChanged: IndexSet(0..<blocks.count))
            needsFullRemeasure = false
        }
        if followsBottom { scrollToBottom() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard needsFullRemeasure, !blocks.isEmpty else { return }
        needsFullRemeasure = false
        table.noteHeightOfRows(withIndexesChanged: IndexSet(0..<blocks.count))
        if followsBottom { scrollToBottom() }
    }

    // MARK: Update

    func update(blocks: [TerminalBlock], live: BlockOutput?, font: NSFont, colors: ThemeColors) {
        var styleChanged = false
        if self.font != font || self.colors != colors {
            self.font = font
            self.colors = colors
            epoch += 1
            styleChanged = true
        }
        let oldOrder = order
        let ids = blocks.map(\.id)
        var changed = [Int]()
        for block in blocks {
            let output = block.isRunning ? live : block.output
            let now = Seen(status: block.status, command: block.command, prompt: block.prompt, output: output)
            if seen[block.id] != now {
                seen[block.id] = now
                revisions[block.id, default: 0] += 1
                changed.append(block.id)
            }
            outputs[block.id] = output
            if output == nil { outputs.removeValue(forKey: block.id) }
        }
        var anchor: (id: Int, offset: CGFloat)?
        if ids != oldOrder {
            let present = Set(ids)
            let appendOnly = !oldOrder.isEmpty && ids.starts(with: oldOrder)
            if !followsBottom, !appendOnly, !styleChanged {
                let top = table.row(at: NSPoint(x: 0, y: clip.bounds.minY))
                if top >= 0, let survivor = oldOrder[top...].first(where: present.contains), let row = oldOrder.firstIndex(of: survivor) {
                    anchor = (survivor, table.rect(ofRow: row).minY - clip.bounds.minY)
                }
            }
            for id in oldOrder where !present.contains(id) {
                outputs.removeValue(forKey: id)
                seen.removeValue(forKey: id)
                revisions.removeValue(forKey: id)
                heights.removeValue(forKey: id)
                matchCache.removeValue(forKey: id)
            }
        }
        self.blocks = blocks
        order = ids

        if styleChanged {
            heights.removeAll()
            table.reloadData()
        } else if ids != oldOrder {
            if !oldOrder.isEmpty, ids.starts(with: oldOrder) {
                table.insertRows(at: IndexSet(oldOrder.count..<ids.count), withAnimation: [])
                let known = Set(oldOrder)
                refresh(ids: changed.filter(known.contains))
            } else {
                table.reloadData()
            }
        } else if !changed.isEmpty {
            refresh(ids: changed)
        }
        let before = selection
        selection.prune(to: ids)
        if selection != before { selectionChanged() }
        if let anchor, let row = order.firstIndex(of: anchor.id) {
            scrollTo(y: table.rect(ofRow: row).minY - anchor.offset)
            followsBottom = isAtBottom
        }
        if !findBar.isHidden, !findBar.query.isEmpty { recomputeMatches(keepCurrent: true) }
        if followsBottom { scrollToBottom() }
    }

    func reset() {
        blocks = []
        order = []
        outputs = [:]
        seen = [:]
        revisions = [:]
        heights = [:]
        selection.clear()
        resetFind()
        followsBottom = true
        table.reloadData()
        selectionChanged()
    }

    private func resetFind() {
        findBar.isHidden = true
        findBar.clear()
        matches = []
        currentMatch = nil
        highlights = [:]
        matchCache = [:]
    }

    private func refresh(ids: [Int]) {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = IndexSet(ids.compactMap { position[$0] })
        guard !rows.isEmpty else { return }
        table.noteHeightOfRows(withIndexesChanged: rows)
        for row in rows {
            if let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BlockRowView { configure(view, row: row) }
        }
    }

    // MARK: Measuring

    private func height(of block: TerminalBlock) -> Height {
        let width = contentWidth
        let revision = revisions[block.id] ?? 0
        if let cached = heights[block.id], cached.width == width, cached.revision == revision, cached.epoch == epoch { return cached }
        let colors = self.colors ?? AppSettings.shared.colors
        let output = outputs[block.id]
        let inner = max(1, width - BlockRowContent.insetLeading - BlockRowContent.insetTrailing)
        let body = measureBody(output?.lines ?? [], width: inner, colors: colors)
        let content = BlockRowContent(block: block, output: output, font: font, colors: colors)
        let entry = Height(
            width: width, revision: revision, epoch: epoch, body: body, total: content.geometry(width: width, bodyHeight: body).total)
        heights[block.id] = entry
        return entry
    }

    private func measureBody(_ lines: [StyledLine], width: CGFloat, colors: ThemeColors) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        if lines.count <= Self.exactLimit {
            measurer.setLines(lines, font: font, colors: colors)
            return measurer.fittingHeight(forWidth: width)
        }
        let sample = Array(lines.prefix(Self.sampleLines))
        measurer.setLines(sample, font: font, colors: colors)
        let sampleHeight = measurer.fittingHeight(forWidth: width)
        let advance = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let columns = max(1, Int(width / advance))
        let sampleVisual = Self.visualLines(sample, columns: columns)
        let perLine = sampleHeight / CGFloat(max(1, sampleVisual))
        return ceil(perLine * CGFloat(Self.visualLines(lines, columns: columns))) + 1
    }

    private static func visualLines(_ lines: [StyledLine], columns: Int) -> Int {
        var total = 0
        for line in lines {
            var cells = line.text.utf16.count
            if line.text.utf8.count != cells {
                cells = line.text.unicodeScalars.reduce(0) { $0 + (isWide($1.value) ? 2 : 1) }
            }
            total += max(1, (cells + columns - 1) / columns)
        }
        return total
    }

    private static func isWide(_ value: UInt32) -> Bool {
        value >= 0x1100 && (value <= 0x115F || (0x2E80...0xA4CF).contains(value) || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0xFE30...0xFE6F).contains(value) || (0xFF00...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value) || (0x1F300...0x1FAFF).contains(value) || (0x20000...0x3FFFD).contains(value))
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { blocks.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard blocks.indices.contains(row) else { return 1 }
        return height(of: blocks[row]).total
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard blocks.indices.contains(row) else { return nil }
        let view = (tableView.makeView(withIdentifier: BlockRowView.identifier, owner: nil) as? BlockRowView)
            ?? BlockRowView(frame: .zero)
        view.onClick = { [weak self] id, event in self?.click(id, event: event) }
        view.onMenu = { [weak self] id in self?.menu(forBlock: id) }
        view.onTextSelected = { [weak self] in self?.clearSelection(focus: false) }
        view.onKey = { [weak self] event in self?.routeKey(event) ?? false }
        configure(view, row: row)
        return view
    }

    private func configure(_ view: BlockRowView, row: Int) {
        let block = blocks[row]
        let colors = self.colors ?? AppSettings.shared.colors
        view.configure(
            block: block, output: outputs[block.id], revision: revisions[block.id] ?? 0, epoch: epoch, bodyHeight: height(of: block).body,
            font: font, colors: colors, selected: selection.contains(block.id))
        view.applyFind(highlights[block.id])
    }

    var rowViewCount: Int { table.subviews.filter { $0 is NSTableRowView }.count }

    var blockCount: Int { blocks.count }

    // MARK: Selection

    var selectedBlockIDs: [Int] { selection.ordered(in: order) }

    private func click(_ id: Int, event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            selection.toggle(id)
        } else if flags.contains(.shift) {
            selection.selectRange(to: id, in: order)
        } else {
            selection.select(id)
        }
        selectionChanged()
        focusList()
    }

    func clearSelection(focus: Bool = false) {
        guard !selection.isEmpty else { return }
        selection.clear()
        selectionChanged()
        if focus { focusList() }
    }

    private func selectionChanged() {
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<NSMaxRange(visible) where blocks.indices.contains(row) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BlockRowView)?.isBlockSelected = selection.contains(blocks[row].id)
        }
        onSelectionChange?()
    }

    func focusList() {
        window?.makeFirstResponder(table)
    }

    func moveSelection(_ delta: Int, extend: Bool) {
        guard let id = selection.move(delta, extend: extend, in: order), let row = order.firstIndex(of: id) else { return }
        selectionChanged()
        reveal(row: row)
        focusList()
    }

    // MARK: Keys

    private func routeKey(_ event: NSEvent) -> Bool {
        switch BlockKeyKind.classify(event) {
        case .escape:
            clearSelection()
            onFocusEditor?(nil)
            return true
        case .typing:
            clearSelection()
            onFocusEditor?(event)
            return true
        case .other:
            return false
        }
    }

    func handleKeyEquivalent(_ event: NSEvent, fromEditor: Bool) -> Bool {
        guard event.type == .keyDown else { return false }
        let responder = window?.firstResponder as? NSView
        let inFind = responder.map { $0.isDescendant(of: findBar) } ?? false
        let inList = responder.map { $0.isDescendant(of: scroll) } ?? false
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let code = event.keyCode

        if code == 3, flags == .command {
            showFind()
            return true
        }
        if code == 5, flags == .command || flags == [.command, .shift], !matches.isEmpty || !findBar.query.isEmpty {
            stepMatch(flags.contains(.shift) ? -1 : 1)
            return true
        }
        guard !inFind, inList || fromEditor else { return false }
        if code == 126 || code == 125, flags == .command || flags == [.command, .shift] {
            if fromEditor, code == 125, selection.isEmpty { return false }
            moveSelection(code == 126 ? -1 : 1, extend: flags.contains(.shift))
            return true
        }
        guard code == 8, !selection.isEmpty else { return false }
        switch flags {
        case .command:
            if let text = responder as? BlockOutputTextView, text.selectedRange().length > 0 { return false }
            return inList && copySelection(.commandAndOutput)
        case [.command, .shift]: return copySelection(.command)
        case [.command, .shift, .option]: return copySelection(.output)
        default: return false
        }
    }

    // MARK: Copy

    private func commandAndOutput(of id: Int) -> (command: String, output: String)? {
        guard let block = blocks.first(where: { $0.id == id }) else { return nil }
        return (block.command, outputs[id]?.plainText ?? "")
    }

    @discardableResult
    func copySelection(_ part: BlockCopy) -> Bool {
        let ids = selection.ordered(in: order)
        guard !ids.isEmpty else { return false }
        let text = part.text(blocks: ids.compactMap(commandAndOutput(of:)))
        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return true
    }

    // MARK: Menu

    func menu(forBlock id: Int) -> NSMenu {
        if !selection.contains(id) {
            selection.select(id)
            selectionChanged()
        }
        let menu = NSMenu()
        func add(_ title: String, _ run: @escaping () -> Void) {
            let action = MenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action
            menu.addItem(item)
        }
        add("Copiar comando") { [weak self] in self?.copySelection(.command) }
        add("Copiar saída") { [weak self] in self?.copySelection(.output) }
        add("Copiar comando e saída") { [weak self] in self?.copySelection(.commandAndOutput) }
        menu.addItem(.separator())
        add("Executar de novo") { [weak self] in
            guard let self, let command = self.commandAndOutput(of: id)?.command else { return }
            var text = command
            while text.last == "\n" { text.removeLast() }
            if self.onRerun?(text) != true { NSSound.beep() }
        }
        menu.addItem(.separator())
        add("Ir para o topo do bloco") { [weak self] in self?.goToTop(of: id) }
        add("Ir para o fim do bloco") { [weak self] in self?.goToEnd(of: id) }
        return menu
    }

    func goToTop(of id: Int) {
        guard let row = order.firstIndex(of: id) else { return }
        followsBottom = false
        scrollTo(y: table.rect(ofRow: row).minY)
        followsBottom = isAtBottom
    }

    func goToEnd(of id: Int) {
        guard let row = order.firstIndex(of: id) else { return }
        followsBottom = false
        scrollTo(y: table.rect(ofRow: row).maxY - clip.bounds.height)
        followsBottom = isAtBottom
    }

    // MARK: Find

    var isFindOpen: Bool { !findBar.isHidden }

    func showFind() {
        findBar.isHidden = false
        findBar.show()
    }

    func closeFind() {
        resetFind()
        refreshFindMarks()
        onFocusEditor?(nil)
    }

    func setQuery(_ query: String) {
        recomputeMatches(keepCurrent: false, query: query)
        if let current = currentMatch { revealMatch(matches[current]) }
    }

    private func stepMatch(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let current = ((currentMatch ?? (delta > 0 ? -1 : 0)) + delta + matches.count) % matches.count
        currentMatch = current
        buildHighlights()
        refreshFindMarks()
        findBar.setCount(current: current + 1, total: matches.count)
        revealMatch(matches[current])
    }

    private func recomputeMatches(keepCurrent: Bool, query: String? = nil) {
        let query = query ?? findBar.query
        let kept = keepCurrent ? currentMatch.flatMap { matches.indices.contains($0) ? matches[$0] : nil } : nil
        let previous = currentMatch
        var found = [BlockMatch]()
        for block in blocks {
            let revision = revisions[block.id] ?? 0
            if let cached = matchCache[block.id], cached.query == query, cached.revision == revision {
                found += cached.matches
                continue
            }
            let own = BlockSearch.matches(
                for: query, in: [(id: block.id, command: block.command, output: outputs[block.id]?.plainText ?? "")])
            matchCache[block.id] = (query, revision, own)
            found += own
        }
        matches = found
        if matches.isEmpty {
            currentMatch = nil
        } else if let kept, let index = matches.firstIndex(of: kept) {
            currentMatch = index
        } else {
            currentMatch = keepCurrent ? min(previous ?? 0, matches.count - 1) : 0
        }
        buildHighlights()
        refreshFindMarks()
        findBar.setCount(current: currentMatch.map { $0 + 1 }, total: matches.count)
    }

    private func buildHighlights() {
        var result = [Int: BlockFindHighlight]()
        let current = currentMatch.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        for match in matches {
            var entry = result[match.blockID] ?? BlockFindHighlight(command: [], output: [], current: nil)
            if match.field == .command { entry.command.append(match.range) } else { entry.output.append(match.range) }
            if current?.blockID == match.blockID { entry.current = current }
            result[match.blockID] = entry
        }
        highlights = result
    }

    private func refreshFindMarks() {
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<NSMaxRange(visible) where blocks.indices.contains(row) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BlockRowView)?.applyFind(highlights[blocks[row].id])
        }
    }

    private func revealMatch(_ match: BlockMatch) {
        guard let row = order.firstIndex(of: match.blockID) else { return }
        reveal(row: row)
        guard match.field == .output,
              let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? BlockRowView else { return }
        view.applyFind(highlights[match.blockID])
        guard let local = view.outputRect(forCharacters: match.range) else { return }
        let rect = table.convert(local, from: view)
        let visible = clip.bounds
        if rect.minY < visible.minY || rect.maxY > visible.maxY {
            followsBottom = false
            scrollTo(y: rect.midY - visible.height / 2)
            followsBottom = isAtBottom
        }
    }
}
