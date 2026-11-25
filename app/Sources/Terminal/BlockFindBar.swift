import AppKit
import WispCore

@MainActor
final class BlockFindBar: NSView, NSSearchFieldDelegate {
    private let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    static let size = NSSize(width: 320, height: 34)

    var query: String { field.stringValue }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(Theme.surfaceHi).cgColor
        layer?.borderColor = NSColor(Theme.stroke).cgColor
        layer?.borderWidth = 1
        field.placeholderString = "Buscar nos blocos"
        field.delegate = self
        field.font = NSFont.systemFont(ofSize: 12)
        field.focusRingType = .none
        addSubview(field)
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = NSColor(Theme.textSecondary)
        countLabel.alignment = .right
        addSubview(countLabel)
        configure(previousButton, symbol: "chevron.up", label: "Anterior", action: #selector(previous))
        configure(nextButton, symbol: "chevron.down", label: "Próxima", action: #selector(next))
        configure(closeButton, symbol: "xmark", label: "Fechar busca", action: #selector(close))
    }

    required init?(coder: NSCoder) { nil }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        button.contentTintColor = NSColor(Theme.textSecondary)
        button.target = self
        button.action = action
        addSubview(button)
    }

    func clear() {
        field.stringValue = ""
        countLabel.stringValue = ""
    }

    func show() {
        isHidden = false
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func setCount(current: Int?, total: Int) {
        if field.stringValue.isEmpty {
            countLabel.stringValue = ""
        } else if total == 0 {
            countLabel.stringValue = "0"
        } else {
            countLabel.stringValue = "\(current ?? 0)/\(total)"
        }
    }

    override func layout() {
        super.layout()
        let button: CGFloat = 22
        var right = bounds.width - 8
        closeButton.frame = NSRect(x: right - button, y: 6, width: button, height: button)
        right = closeButton.frame.minX
        nextButton.frame = NSRect(x: right - button, y: 6, width: button, height: button)
        previousButton.frame = NSRect(x: nextButton.frame.minX - button, y: 6, width: button, height: button)
        countLabel.frame = NSRect(x: previousButton.frame.minX - 52, y: 9, width: 48, height: 16)
        field.frame = NSRect(x: 8, y: 5, width: max(40, countLabel.frame.minX - 12), height: 24)
    }

    @objc private func previous() { onPrevious?() }
    @objc private func next() { onNext?() }
    @objc private func close() { onClose?() }

    func controlTextDidChange(_ notification: Notification) { onQueryChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        default:
            return false
        }
    }
}
