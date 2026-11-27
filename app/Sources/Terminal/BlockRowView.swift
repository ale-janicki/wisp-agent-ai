import AppKit
import WispCore

struct BlockRowContent {
    static let insetLeading: CGFloat = 12
    static let insetTrailing: CGFloat = 12
    static let insetVertical: CGFloat = 8
    static let gap: CGFloat = 6
    static let glyphSize: CGFloat = 14
    static let menuButtonSize: CGFloat = 20
    static let minimumCommandHeight: CGFloat = 16
    static let bannerHeight: CGFloat = 14

    struct Geometry {
        var prompt: CGFloat
        var command: CGFloat
        var commandWidth: CGFloat
        var durationWidth: CGFloat
        var banner: CGFloat
        var body: CGFloat
        var total: CGFloat
    }

    let command: NSAttributedString
    let prompt: NSAttributedString?
    let duration: NSAttributedString?
    let banner: NSAttributedString?

    @MainActor
    init(block: TerminalBlock, output: BlockOutput?, font: NSFont, colors: ThemeColors) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        var text = block.command
        while text.last == "\n" { text.removeLast() }
        command = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold),
            .foregroundColor: TerminalTheme.ns(colors.textPrimary),
            .paragraphStyle: paragraph,
        ])
        if block.prompt.isEmpty {
            prompt = nil
        } else {
            let small = NSFont.monospacedSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)
            prompt = SwiftTermStyle.attributed(block.prompt, font: small, colors: colors)
        }
        let caption: String?
        if block.isRunning {
            caption = block.interrupted ? "interrompendo…" : nil
        } else {
            let seconds = block.duration.map(BlockDuration.text)
            caption = block.interrupted ? [seconds, "interrompido"].compactMap { $0 }.joined(separator: " · ") : seconds
        }
        if let caption {
            duration = NSAttributedString(string: caption, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: TerminalTheme.ns(block.interrupted ? colors.textTertiary : colors.textSecondary),
            ])
        } else {
            duration = nil
        }
        if let dropped = output?.droppedLines, dropped > 0 {
            banner = NSAttributedString(string: "\(dropped) linhas anteriores omitidas", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: TerminalTheme.ns(colors.textSecondary),
            ])
        } else {
            banner = nil
        }
    }

    private static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let box = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        return ceil(text.boundingRect(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 1
    }

    func geometry(width: CGFloat, bodyHeight: CGFloat) -> Geometry {
        let inner = max(1, width - Self.insetLeading - Self.insetTrailing)
        let promptHeight = prompt.map { Self.height(of: $0, width: inner) } ?? 0
        let durationWidth = duration.map { ceil($0.size().width) + 2 } ?? 0
        var accessories = Self.menuButtonSize + Self.gap + Self.glyphSize
        if durationWidth > 0 { accessories += Self.gap + durationWidth }
        let commandWidth = max(1, inner - accessories - Self.gap)
        let commandHeight = max(Self.minimumCommandHeight, Self.height(of: command, width: commandWidth))
        let banner = self.banner == nil ? 0 : Self.bannerHeight
        var total = Self.insetVertical
        if promptHeight > 0 { total += promptHeight + 2 }
        total += commandHeight
        if banner > 0 { total += Self.gap + banner }
        if bodyHeight > 0 { total += Self.gap + bodyHeight }
        total += Self.insetVertical
        return Geometry(
            prompt: promptHeight, command: commandHeight, commandWidth: commandWidth, durationWidth: durationWidth,
            banner: banner, body: bodyHeight, total: total)
    }
}

struct BlockFindHighlight: Equatable {
    var command: [Range<Int>]
    var output: [Range<Int>]
    var current: BlockMatch?
}

@MainActor
final class BlockRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BlockRowView")
    private static let barWidth: CGFloat = 3
    private static let tint = 0.06

    private let promptLabel = NSTextField(labelWithString: "")
    private let commandLabel = NSTextField(labelWithString: "")
    private let bannerLabel = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private let durationLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton()
    private let body = BlockOutputTextView()

    private(set) var blockID: Int?
    private var failed = false
    private var content: BlockRowContent?
    private var bodyHeight: CGFloat = 0
    private var renderedKey: (id: Int, revision: Int, epoch: Int)?
    private var renderedFind: BlockFindHighlight??
    private var hovering = false

    var onClick: ((Int, NSEvent) -> Void)?
    var onMenu: ((Int) -> NSMenu?)?
    var onTextSelected: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    var isBlockSelected = false {
        didSet { if isBlockSelected != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        for label in [promptLabel, commandLabel, bannerLabel, durationLabel] {
            label.isSelectable = false
            label.drawsBackground = false
            label.isBezeled = false
            label.maximumNumberOfLines = 0
            label.cell?.wraps = true
            label.cell?.isScrollable = false
            label.lineBreakMode = .byCharWrapping
            addSubview(label)
        }
        promptLabel.alphaValue = 0.75
        durationLabel.maximumNumberOfLines = 1
        durationLabel.lineBreakMode = .byClipping
        bannerLabel.maximumNumberOfLines = 1
        bannerLabel.lineBreakMode = .byTruncatingTail
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)
        menuButton.isBordered = false
        menuButton.bezelStyle = .regularSquare
        menuButton.imagePosition = .imageOnly
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Ações do bloco")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        menuButton.contentTintColor = NSColor(Theme.textSecondary)
        menuButton.target = self
        menuButton.action = #selector(showMenuFromButton)
        menuButton.isHidden = true
        addSubview(menuButton)
        addSubview(body)
        body.onBlockClick = { [weak self] event in
            guard let self, let id = self.blockID else { return }
            self.onClick?(id, event)
        }
        body.onTextSelected = { [weak self] in self?.onTextSelected?() }
        body.onContextMenu = { [weak self] _ in
            guard let self, let id = self.blockID else { return nil }
            return self.onMenu?(id)
        }
        body.onKey = { [weak self] event in self?.onKey?(event) ?? false }
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Content

    func configure(
        block: TerminalBlock, output: BlockOutput?, revision: Int, epoch: Int, bodyHeight: CGFloat, font: NSFont, colors: ThemeColors,
        selected: Bool
    ) {
        isBlockSelected = selected
        let key = (id: block.id, revision: revision, epoch: epoch)
        let unchanged = renderedKey.map { $0 == key } ?? false
        blockID = block.id
        if unchanged, abs(self.bodyHeight - bodyHeight) < 0.5 { return }
        let fresh = BlockRowContent(block: block, output: output, font: font, colors: colors)
        content = fresh
        self.bodyHeight = bodyHeight
        if !unchanged {
            renderedKey = key
            renderedFind = nil
            applyHeader(block: block, content: fresh, colors: colors)
            body.setLines(output?.lines ?? [], font: font, colors: colors)
        }
        needsLayout = true
        needsDisplay = true
    }

    private func applyHeader(block: TerminalBlock, content: BlockRowContent, colors: ThemeColors) {
        commandLabel.attributedStringValue = content.command
        promptLabel.attributedStringValue = content.prompt ?? NSAttributedString()
        promptLabel.isHidden = content.prompt == nil
        durationLabel.attributedStringValue = content.duration ?? NSAttributedString()
        durationLabel.isHidden = content.duration == nil
        bannerLabel.attributedStringValue = content.banner ?? NSAttributedString()
        bannerLabel.isHidden = content.banner == nil
        let symbol: String
        let tint: NSColor
        switch block.status {
        case .running: (symbol, tint) = ("circle.lefthalf.filled", NSColor(Theme.accent))
        case .finished(0): (symbol, tint) = ("checkmark.circle.fill", NSColor(Theme.ok))
        case .finished: (symbol, tint) = ("xmark.circle.fill", NSColor(Theme.error))
        case .lost: (symbol, tint) = ("questionmark.circle", NSColor(Theme.textSecondary))
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        glyph.contentTintColor = tint
        if case .finished(let code) = block.status, code != 0 { failed = true } else { failed = false }
    }

    func applyFind(_ find: BlockFindHighlight?) {
        if let renderedFind, renderedFind == find { return }
        renderedFind = .some(find)
        if let content {
            let command = NSMutableAttributedString(attributedString: content.command)
            let length = command.length
            for range in find?.command ?? [] where range.upperBound <= length {
                let isCurrent = find?.current?.field == .command && find?.current?.range == range
                command.addAttribute(
                    .backgroundColor, value: (isCurrent ? NSColor.systemOrange.withAlphaComponent(0.7) : NSColor.systemYellow.withAlphaComponent(0.35)),
                    range: NSRange(location: range.lowerBound, length: range.count))
            }
            commandLabel.attributedStringValue = command
        }
        let current = find?.current?.field == .output ? find?.current?.range : nil
        body.setHighlights(find?.output ?? [], current: current)
    }

    func outputRect(forCharacters range: Range<Int>) -> NSRect? {
        layoutSubtreeIfNeeded()
        guard let rect = body.rect(forCharacters: range) else { return nil }
        return NSRect(x: body.frame.minX + rect.minX, y: body.frame.minY + rect.minY, width: rect.width, height: rect.height)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
        menuButton.isHidden = true
        renderedKey = nil
        renderedFind = nil
        blockID = nil
        isBlockSelected = false
    }

    // MARK: Geometry

    override func layout() {
        super.layout()
        guard let content else { return }
        let metrics = content.geometry(width: bounds.width, bodyHeight: bodyHeight)
        let x = BlockRowContent.insetLeading
        let inner = max(1, bounds.width - BlockRowContent.insetLeading - BlockRowContent.insetTrailing)
        var y = BlockRowContent.insetVertical
        if metrics.prompt > 0 {
            promptLabel.frame = NSRect(x: x, y: y, width: inner, height: metrics.prompt)
            y += metrics.prompt + 2
        }
        commandLabel.frame = NSRect(x: x, y: y, width: metrics.commandWidth, height: metrics.command)
        let right = x + inner
        glyph.frame = NSRect(x: right - BlockRowContent.glyphSize, y: y, width: BlockRowContent.glyphSize, height: BlockRowContent.glyphSize)
        var cursor = glyph.frame.minX
        if metrics.durationWidth > 0 {
            cursor -= BlockRowContent.gap + metrics.durationWidth
            durationLabel.frame = NSRect(x: cursor, y: y + 1, width: metrics.durationWidth, height: 14)
        }
        cursor -= BlockRowContent.gap + BlockRowContent.menuButtonSize
        menuButton.frame = NSRect(x: cursor, y: y - 2, width: BlockRowContent.menuButtonSize, height: BlockRowContent.menuButtonSize)
        y += metrics.command
        if metrics.banner > 0 {
            bannerLabel.frame = NSRect(x: x, y: y + BlockRowContent.gap, width: inner, height: metrics.banner)
            y += BlockRowContent.gap + metrics.banner
        }
        body.isHidden = metrics.body == 0
        if metrics.body > 0 { body.frame = NSRect(x: x, y: y + BlockRowContent.gap, width: inner, height: metrics.body) }
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !menuButton.isHidden, menuButton.frame.contains(local) { return menuButton }
        if !body.isHidden, body.frame.contains(local) { return body }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let id = blockID else { return }
        onClick?(id, event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = blockID else { return nil }
        return onMenu?(id)
    }

    @objc private func showMenuFromButton() {
        guard let id = blockID, let menu = onMenu?(id) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.height + 2), in: menuButton)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        menuButton.isHidden = blockID == nil
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        menuButton.isHidden = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if failed {
            NSColor(Theme.error).withAlphaComponent(Self.tint).setFill()
            bounds.fill()
            NSColor(Theme.error).setFill()
            NSRect(x: 0, y: 0, width: Self.barWidth, height: bounds.height).fill()
        }
        if isBlockSelected {
            NSColor(Theme.accentFill).setFill()
            bounds.fill()
        }
        NSColor(Theme.stroke).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
