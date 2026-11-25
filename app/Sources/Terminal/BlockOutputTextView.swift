import AppKit
import WispCore

@MainActor
final class BlockOutputTextView: NSTextView {
    private(set) var lines = [StyledLine]()
    private var highlights = [Range<Int>]()
    private var currentHighlight: Range<Int>?

    var onBlockClick: ((NSEvent) -> Void)?
    var onTextSelected: (() -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    var onKey: ((NSEvent) -> Bool)?

    private static let maxHighlights = 300

    init() {
        let storage = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        storage.addTextLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        allowsUndo = false
        textContainerInset = .zero
        isHorizontallyResizable = false
        isVerticallyResizable = false
        selectedTextAttributes = [.backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.35)]
    }

    required init?(coder: NSCoder) { nil }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    func setLines(_ lines: [StyledLine], font: NSFont, colors: ThemeColors) {
        self.lines = lines
        textStorage?.setAttributedString(SwiftTermStyle.attributed(lines, font: font, colors: colors))
        applyHighlights()
    }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        lines.isEmpty ? 0 : fittingTextHeight(forWidth: width)
    }

    // MARK: Find highlights

    func setHighlights(_ ranges: [Range<Int>], current: Range<Int>?) {
        guard ranges != highlights || current != currentHighlight else { return }
        highlights = ranges
        currentHighlight = current
        applyHighlights()
    }

    private func applyHighlights() {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange)
        let length = textStorage?.length ?? 0
        func textRange(_ range: Range<Int>) -> NSTextRange? {
            guard range.lowerBound < length, range.upperBound <= length,
                  let start = content.location(layout.documentRange.location, offsetBy: range.lowerBound),
                  let end = content.location(start, offsetBy: range.count) else { return nil }
            return NSTextRange(location: start, end: end)
        }
        for range in highlights.prefix(Self.maxHighlights) where range != currentHighlight {
            if let found = textRange(range) {
                layout.setRenderingAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35)], for: found)
            }
        }
        if let currentHighlight, let found = textRange(currentHighlight) {
            layout.setRenderingAttributes([.backgroundColor: NSColor.systemOrange.withAlphaComponent(0.7)], for: found)
        }
        needsDisplay = true
    }

    func rect(forCharacters range: Range<Int>) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(layout.documentRange.location, offsetBy: range.lowerBound) else { return nil }
        let end = content.location(start, offsetBy: max(1, range.count)) ?? layout.documentRange.endLocation
        guard let textRange = NSTextRange(location: start, end: end) else { return nil }
        var found: NSRect?
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            found = frame
            return false
        }
        return found
    }

    // MARK: Mouse and keys

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.shift) {
            onBlockClick?(event)
            return
        }
        let before = selectedRange()
        super.mouseDown(with: event)
        let after = selectedRange()
        if after.length > 0 {
            if after != before {
                onTextSelected?()
                copySelectionToPasteboard()
            }
        } else if event.clickCount == 1 {
            onBlockClick?(event)
        }
    }

    private func copySelectionToPasteboard() {
        let range = selectedRange()
        let text = string as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.substring(with: range), forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?(event) }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if TextShortcuts.perform(event, in: self, canEdit: false) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

extension NSTextView {
    func fittingTextHeight(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer else { return 0 }
        container.size = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        if let layout = textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
            return ceil(layout.usageBoundsForTextContainer.height)
        }
        if let layout = layoutManager {
            layout.ensureLayout(for: container)
            return ceil(layout.usedRect(for: container).height)
        }
        return 0
    }
}

@MainActor
enum TextShortcuts {
    static func perform(_ event: NSEvent, in view: NSTextView, canEdit: Bool) -> Bool {
        guard event.type == .keyDown, view.window?.firstResponder === view else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "c": view.copy(nil)
        case "a": view.selectAll(nil)
        case "v" where canEdit: view.paste(nil)
        case "x" where canEdit: view.cut(nil)
        default: return false
        }
        return true
    }
}

enum BlockKeyKind {
    case escape
    case typing
    case other

    static func classify(_ event: NSEvent) -> BlockKeyKind {
        if event.keyCode == 53 { return .escape }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control) else { return .other }
        let characters = event.characters ?? ""
        if characters.isEmpty { return .typing }
        let text = characters.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
        return text ? .typing : .other
    }
}
