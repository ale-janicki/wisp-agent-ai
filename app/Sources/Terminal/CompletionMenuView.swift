import AppKit
import WispCore

@MainActor
final class CompletionMenuView: NSView {
    static let maxRows = 10
    private static let rowHeight: CGFloat = 24
    private static let padding: CGFloat = 4
    private static let iconWidth: CGFloat = 22
    private static let headerHeight: CGFloat = 24

    var onPick: ((Int) -> Void)?
    private var items = [Completion]()
    private var selected = 0
    private var top = 0
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var header: String?
    private var symbol: String?
    private var headerSpace: CGFloat { header == nil ? 0 : Self.headerHeight }

    override var isFlipped: Bool { true }

    static func visibleRows(for count: Int) -> Int { min(count, maxRows) }

    static func height(rows: Int, header: Bool = false) -> CGFloat { CGFloat(rows) * rowHeight + padding * 2 + (header ? headerHeight : 0) }

    func fittingWidth(limit: CGFloat) -> CGFloat {
        let widest = items.map { ($0.display as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(limit, max(160, ceil(widest) + Self.iconWidth + 24 + Self.padding * 2))
    }

    func update(items: [Completion], selected: Int, font: NSFont, header: String? = nil, symbol: String? = nil) {
        self.items = items
        self.font = font
        self.header = header
        self.symbol = symbol
        self.selected = items.isEmpty ? 0 : min(max(0, selected), items.count - 1)
        revealSelection()
        needsDisplay = true
    }

    private var rows: Int { max(1, Int((bounds.height - Self.padding * 2 - headerSpace) / Self.rowHeight)) }

    private func revealSelection() {
        let rows = min(Self.maxRows, rows)
        if selected < top { top = selected } else if selected >= top + rows { top = selected - rows + 1 }
        top = max(0, min(top, max(0, items.count - rows)))
    }

    override func layout() {
        super.layout()
        revealSelection()
    }

    // MARK: Mouse

    override func scrollWheel(with event: NSEvent) {
        let step = event.scrollingDeltaY > 0 ? -1 : (event.scrollingDeltaY < 0 ? 1 : 0)
        guard step != 0 else { return }
        top = max(0, min(top + step, max(0, items.count - rows)))
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let y = point.y - headerSpace
        let index = top + Int((y - Self.padding) / Self.rowHeight)
        if y >= Self.padding, items.indices.contains(index) { onPick?(index) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor(Theme.surfaceHi).setFill()
        shape.fill()
        NSColor(Theme.stroke).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        if let header {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Theme.textTertiary)]
            let size = (header as NSString).size(withAttributes: attributes)
            (header as NSString).draw(
                in: NSRect(x: Self.padding + 8, y: Self.padding + (Self.headerHeight - Self.padding - size.height) / 2 + 2, width: bounds.width - Self.padding * 2 - 16, height: size.height),
                withAttributes: attributes)
        }
        let shown = items.indices.filter { $0 >= top && $0 < top + rows }
        for index in shown {
            let row = NSRect(
                x: Self.padding, y: Self.padding + headerSpace + CGFloat(index - top) * Self.rowHeight, width: bounds.width - Self.padding * 2,
                height: Self.rowHeight)
            if index == selected {
                NSColor(Theme.accentFill).setFill()
                NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
            }
            let item = items[index]
            drawIcon(for: item.kind, in: NSRect(x: row.minX + 4, y: row.minY, width: Self.iconWidth, height: row.height))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor(index == selected ? Theme.textPrimary : Theme.textSecondary),
            ]
            let size = (item.display as NSString).size(withAttributes: attributes)
            let textRect = NSRect(
                x: row.minX + 4 + Self.iconWidth, y: row.minY + (row.height - size.height) / 2,
                width: row.width - Self.iconWidth - 8, height: size.height)
            (item.display as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }

    private func drawIcon(for kind: Completion.Kind, in rect: NSRect) {
        var (symbol, color): (String, NSColor) = switch kind {
        case .dir: ("folder.fill", NSColor(Theme.accent))
        case .file: ("doc", NSColor(Theme.textTertiary))
        case .exec: ("terminal", NSColor(Theme.ok))
        case .builtin: ("command", NSColor(Theme.busy))
        }
        if let override = self.symbol {
            symbol = override
            color = NSColor(Theme.textTertiary)
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }
}
