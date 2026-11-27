import AppKit
import WispCore

@MainActor
final class ContextChipsView: NSView {
    static let height: CGFloat = 20
    private static let gap: CGFloat = 6
    private static let padding: CGFloat = 8
    private static let iconGap: CGFloat = 4

    private struct Segment {
        var text: String
        var color: NSColor
    }

    private struct Chip {
        var symbol: String?
        var segments: [Segment]
        var tint: NSColor
        var fill: NSColor
    }

    private var chips = [Chip]()

    override var isFlipped: Bool { true }

    func update(directory: String, git: GitStatus?) {
        var next = [
            Chip(
                symbol: nil, segments: [Segment(text: ContextChips.directoryLabel(directory, home: NSHomeDirectory()), color: NSColor(Theme.textSecondary))],
                tint: NSColor(Theme.textSecondary), fill: NSColor(Theme.surfaceHi))
        ]
        if let git {
            let alert = git.isDefaultBranch
            let branchColor = NSColor(alert ? Theme.busy : Theme.accentText)
            next.append(
                Chip(
                    symbol: "arrow.triangle.branch", segments: [Segment(text: git.branch, color: branchColor)], tint: branchColor,
                    fill: alert ? NSColor(Theme.busy).withAlphaComponent(0.18) : NSColor(Theme.accentFill)))
            if git.isDirty {
                next.append(
                    Chip(
                        symbol: nil,
                        segments: [
                            Segment(text: "● \(git.changedFiles)", color: NSColor(Theme.busy)),
                            Segment(text: "+\(git.insertions)", color: NSColor(Theme.ok)),
                            Segment(text: "−\(git.deletions)", color: NSColor(Theme.error)),
                        ], tint: NSColor(Theme.textSecondary), fill: NSColor(Theme.surfaceHi)))
            }
        }
        chips = next
        needsDisplay = true
    }

    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font]
        for chip in chips {
            let widths = chip.segments.map { ($0.text as NSString).size(withAttributes: attributes).width }
            let icon = chip.symbol.flatMap { symbol(named: $0, color: chip.tint) }
            let iconWidth = icon.map { $0.size.width + Self.iconGap } ?? 0
            let textWidth = widths.reduce(0, +) + CGFloat(max(0, chip.segments.count - 1)) * Self.iconGap
            let width = Self.padding * 2 + iconWidth + textWidth
            let rect = NSRect(x: x, y: 0, width: width, height: Self.height)
            guard rect.minX < bounds.width else { break }
            chip.fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.artwork / 2, yRadius: Theme.Radius.artwork / 2).fill()
            var cursor = x + Self.padding
            if let icon {
                icon.draw(in: NSRect(x: cursor, y: (Self.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
                cursor += iconWidth
            }
            for (segment, segmentWidth) in zip(chip.segments, widths) {
                let size = (segment.text as NSString).size(withAttributes: attributes)
                (segment.text as NSString).draw(
                    at: NSPoint(x: cursor, y: (Self.height - size.height) / 2),
                    withAttributes: [.font: Self.font, .foregroundColor: segment.color])
                cursor += segmentWidth + Self.iconGap
            }
            x += width + Self.gap
        }
    }

    private func symbol(named name: String, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}
