import AppKit
import WispCore

@MainActor
final class InputEditorView: NSTextView {
    var onSubmit: ((String) -> Bool)?
    var onKey: ((TerminalKey, Bool) -> Void)?
    var onPaste: ((String) -> Void)?
    var onHeightChange: (() -> Void)?
    var completionProvider: ((String, Int) -> [Completion])?
    var onCompletionsChange: (() -> Void)?
    var onClear: (() -> Void)?
    var history = CommandHistory.shared
    private var navigator = HistoryNavigator()
    private var applyingHistory = false
    private(set) var searchQuery: String?
    private(set) var searchResults = [String]()
    private(set) var searchSelection = 0
    var onSearchChange: (() -> Void)?
    var isSearchingHistory: Bool { searchQuery != nil }
    var searchDisplayQuery: String? { searchQuery.map { $0 + detachedMarked } }
    private var baseAttributes = [NSAttributedString.Key: Any]()
    private var detachedMarked = ""
    private var isDetached: Bool { isSearchingHistory || forwardsKeys }
    var isProgram: ((String) -> Bool)?
    var isProgramPrefix: ((String) -> Bool)?
    private(set) var completions = [Completion]()
    private(set) var completionSelection = 0
    private var selectionMoved = false
    private var applyingCompletion = false
    private var handlingKey = false
    var isCompletionMenuOpen: Bool { !completions.isEmpty }
    var forwardsKeys = false {
        didSet {
            guard oldValue != forwardsKeys else { return }
            needsDisplay = true
            closeCompletions()
            closeHistorySearch()
        }
    }
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let backspace: UInt16 = 51
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    static let maxVisibleLines = 10

    init() {
        super.init(frame: .zero)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        textContainerInset = .zero
        isHorizontallyResizable = false
        isVerticallyResizable = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    func apply(font: NSFont, colors: ThemeColors) {
        self.font = font
        textColor = TerminalTheme.ns(colors.textPrimary)
        insertionPointColor = TerminalTheme.ns(colors.accent)
        selectedTextAttributes = [.backgroundColor: TerminalTheme.ns(colors.accent).withAlphaComponent(0.35)]
        baseAttributes = [.font: font, .foregroundColor: TerminalTheme.ns(colors.textPrimary)]
        typingAttributes = baseAttributes
        needsDisplay = true
        highlight()
    }

    private var lineHeight: CGFloat {
        ceil((font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)).boundingRectForFont.height)
    }

    var maxHeight: CGFloat { lineHeight * CGFloat(Self.maxVisibleLines) }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        max(lineHeight, fittingTextHeight(forWidth: width))
    }

    // MARK: Colours

    func highlight() {
        guard let storage = textStorage, !hasMarkedText(), !baseAttributes.isEmpty else { return }
        let base = baseAttributes
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(base, range: full)
        if let isProgram, storage.length > 0 {
            let spans = CommandSyntax.spans(storage.string, isProgram: isProgram, isPrefixOfProgram: isProgramPrefix ?? { _ in false })
            for span in spans {
                let color: NSColor = switch span.kind {
                case .command(let resolved): NSColor(resolved ? Theme.ok : Theme.error)
                case .string: NSColor(Theme.busy)
                case .flag: NSColor(Theme.accentTeal)
                case .path: NSColor(Theme.textSecondary)
                case .plain: NSColor(Theme.textPrimary)
                }
                storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: span.range.lowerBound, length: span.range.count))
            }
        }
        storage.endEditing()
        typingAttributes = base
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if forwardsKeys {
            guard !flags.contains(.command) else { return }
            if hasMarkedText() {
                interpretKeyEvents([event])
            } else if let special = Self.specialKey(event.keyCode) {
                onKey?(special, false)
            } else if flags.contains(.control) {
                if let key = Self.key(for: event, flags: flags) { onKey?(key.key, key.control) }
            } else {
                interpretKeyEvents([event])
            }
            return
        }
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }
        if isSearchingHistory {
            handleSearchKey(event, flags: flags)
            return
        }
        if flags == .control, event.charactersIgnoringModifiers?.lowercased() == "c" {
            onKey?(.text("c"), true)
            string = ""
            didChangeText()
            return
        }
        if handleEditingKey(event, flags: flags) { return }
        if handleCompletionKey(event, flags: flags) { return }
        if handleHistoryKey(event, flags: flags) { return }
        if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.enter, !flags.contains(.command) {
            if flags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if onSubmit?(string) == true {
                string = ""
                didChangeText()
                undoManager?.removeAllActions()
            }
            return
        }
        handlingKey = true
        super.keyDown(with: event)
        handlingKey = false
        guard isCompletionMenuOpen else { return }
        if let typed = event.characters, typed.contains(where: { Self.wordSeparators.contains($0) }) {
            closeCompletions()
        } else {
            refreshCompletions()
        }
    }

    private static let wordSeparators = Set(" ;|&")

    // MARK: Editing keys

    private func handleEditingKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        let plain = flags.subtracting([.numericPad, .function])
        if plain == .control, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "r": openHistorySearch()
            case "l": onClear?()
            case "d":
                if string.isEmpty { onKey?(.text("d"), true) } else { closeCompletions(); deleteForward(nil) }
            case "u": closeCompletions(); deleteToBeginningOfLine(nil)
            case "w": closeCompletions(); deleteWordBackward(nil)
            case "k": closeCompletions(); deleteToEndOfParagraph(nil)
            case "a": closeCompletions(); moveToBeginningOfLine(nil)
            case "e": closeCompletions(); moveToEndOfLine(nil)
            default: return false
            }
            return true
        }
        guard plain == .command || plain == [.command, .shift], event.keyCode == KeyCode.left || event.keyCode == KeyCode.right else {
            return false
        }
        closeCompletions()
        switch (event.keyCode == KeyCode.left, plain.contains(.shift)) {
        case (true, false): moveToBeginningOfLine(nil)
        case (false, false): moveToEndOfLine(nil)
        case (true, true): moveToBeginningOfLineAndModifySelection(nil)
        case (false, true): moveToEndOfLineAndModifySelection(nil)
        }
        return true
    }

    // MARK: History

    private func replaceAll(with text: String) {
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: text) else { return }
        applyingHistory = true
        defer { applyingHistory = false }
        replaceCharacters(in: full, with: text)
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        didChangeText()
    }

    private func handleHistoryKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.subtracting([.numericPad, .function]).isEmpty, selectedRange().length == 0,
              event.keyCode == KeyCode.up || event.keyCode == KeyCode.down else { return false }
        let text = string as NSString
        let cursor = selectedRange().location
        if event.keyCode == KeyCode.up {
            guard navigator.isNavigating || !text.substring(to: cursor).contains("\n") else { return false }
            guard let previous = navigator.back(entries: history.entries, current: string) else { return false }
            replaceAll(with: previous)
        } else {
            guard navigator.isNavigating else { return false }
            guard let next = navigator.forward(entries: history.entries, current: string) else { return false }
            replaceAll(with: next)
        }
        return true
    }

    // MARK: History search (⌃R)

    func openHistorySearch() {
        closeCompletions()
        searchQuery = ""
        searchSelection = 0
        searchResults = history.search("")
        onSearchChange?()
    }

    func closeHistorySearch() {
        guard searchQuery != nil else { return }
        searchQuery = nil
        searchResults = []
        searchSelection = 0
        onSearchChange?()
    }

    func acceptHistoryResult(_ index: Int) {
        guard searchResults.indices.contains(index) else { return }
        let chosen = searchResults[index]
        closeHistorySearch()
        replaceAll(with: chosen)
        navigator.reset()
    }

    private func setSearchQuery(_ query: String) {
        searchQuery = query
        searchSelection = 0
        searchResults = history.search(query)
        onSearchChange?()
    }

    private func moveSearchSelection(by step: Int) {
        guard !searchResults.isEmpty else { return }
        searchSelection = (searchSelection + step + searchResults.count) % searchResults.count
        onSearchChange?()
    }

    private func handleSearchKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) {
        let plain = flags.subtracting([.numericPad, .function, .capsLock])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch event.keyCode {
        case KeyCode.escape:
            closeHistorySearch()
        case KeyCode.returnKey, KeyCode.enter:
            if searchResults.indices.contains(searchSelection) { acceptHistoryResult(searchSelection) } else { closeHistorySearch() }
        case KeyCode.up: moveSearchSelection(by: -1)
        case KeyCode.down: moveSearchSelection(by: 1)
        case KeyCode.backspace:
            if let query = searchQuery, !query.isEmpty { setSearchQuery(String(query.dropLast())) }
        default:
            if plain == .control {
                switch key {
                case "r": moveSearchSelection(by: 1)
                case "c", "g": closeHistorySearch()
                default: break
                }
            } else if plain.isDisjoint(with: [.command, .control]) {
                interpretKeyEvents([event])
            }
        }
    }

    private static func specialKey(_ keyCode: UInt16) -> TerminalKey? {
        switch keyCode {
        case KeyCode.returnKey, KeyCode.enter: .enter
        case KeyCode.backspace: .backspace
        case KeyCode.tab: .tab
        case KeyCode.escape: .escape
        case KeyCode.left: .left
        case KeyCode.right: .right
        case KeyCode.down: .down
        case KeyCode.up: .up
        default: nil
        }
    }

    private static func key(for event: NSEvent, flags: NSEvent.ModifierFlags) -> (key: TerminalKey, control: Bool)? {
        if let special = specialKey(event.keyCode) { return (special, false) }
        let control = flags.contains(.control)
        guard let characters = control ? event.charactersIgnoringModifiers : event.characters, !characters.isEmpty,
              !characters.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return nil }
        return (.text(characters), control)
    }

    // MARK: Completion

    private func handleCompletionKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        let code = event.keyCode
        if code == KeyCode.tab {
            guard isEditable else { return true }
            if flags.contains(.shift) {
                moveCompletion(by: -1)
            } else if isCompletionMenuOpen {
                acceptCompletion(completionSelection)
            } else {
                completeAtCursor()
            }
            return true
        }
        guard isCompletionMenuOpen else { return false }
        switch code {
        case KeyCode.escape:
            closeCompletions()
        case KeyCode.up where !flags.contains(.shift):
            moveCompletion(by: -1)
        case KeyCode.down where !flags.contains(.shift):
            moveCompletion(by: 1)
        case KeyCode.returnKey where !flags.contains(.shift), KeyCode.enter where !flags.contains(.shift):
            guard selectionMoved else {
                closeCompletions()
                return false
            }
            acceptCompletion(completionSelection)
        default:
            return false
        }
        return true
    }

    private var cursorOffset: Int { selectedRange().location + selectedRange().length }

    private func candidates() -> [Completion] {
        guard selectedRange().length == 0 else { return [] }
        return completionProvider?(string, cursorOffset) ?? []
    }

    private func completeAtCursor() {
        let found = candidates()
        guard let first = found.first else { return }
        if found.count == 1 {
            replace(first.replaceRange, with: first.insertText)
            return
        }
        let typed = (string as NSString).substring(with: NSRange(location: first.replaceRange.lowerBound, length: first.replaceRange.count))
        let common = CompletionEngine.commonPrefix(found)
        if common.count > typed.count, common.hasPrefix(typed) { replace(first.replaceRange, with: common) }
        refreshCompletions()
        if completions.count == 1 { closeCompletions() }
    }

    private func refreshCompletions() {
        let found = candidates()
        let current = completions.indices.contains(completionSelection) ? completions[completionSelection].insertText : nil
        completions = found
        let kept = found.firstIndex { $0.insertText == current }
        completionSelection = kept ?? 0
        if kept == nil { selectionMoved = false }
        onCompletionsChange?()
    }

    func closeCompletions() {
        guard !completions.isEmpty else { return }
        completions = []
        completionSelection = 0
        selectionMoved = false
        onCompletionsChange?()
    }

    private func moveCompletion(by step: Int) {
        guard isCompletionMenuOpen else { return }
        completionSelection = (completionSelection + step + completions.count) % completions.count
        selectionMoved = true
        onCompletionsChange?()
    }

    func acceptCompletion(_ index: Int) {
        guard completions.indices.contains(index) else { return }
        let chosen = completions[index]
        completions = []
        completionSelection = 0
        selectionMoved = false
        replace(chosen.replaceRange, with: chosen.insertText)
        onCompletionsChange?()
    }

    private func replace(_ range: Range<Int>, with text: String) {
        let length = (string as NSString).length
        guard range.lowerBound >= 0, range.lowerBound <= length else {
            closeCompletions()
            return
        }
        let target = NSRange(location: range.lowerBound, length: min(range.upperBound, length) - range.lowerBound)
        guard shouldChangeText(in: target, replacementString: text) else { return }
        applyingCompletion = true
        defer { applyingCompletion = false }
        replaceCharacters(in: target, with: text)
        setSelectedRange(NSRange(location: target.location + (text as NSString).length, length: 0))
        didChangeText()
    }

    func completionAnchor() -> NSPoint? {
        guard let first = completions.first, let layoutManager, let textContainer else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(first.replaceRange.lowerBound, max(0, string.utf16.count - 1)))
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        return NSPoint(x: rect.minX + textContainerInset.width, y: rect.minY + textContainerInset.height)
    }

    override func mouseDown(with event: NSEvent) {
        closeCompletions()
        closeHistorySearch()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if (flags == .command || flags == [.command, .shift]), event.charactersIgnoringModifiers?.lowercased() == "z",
           window?.firstResponder === self, !forwardsKeys {
            closeCompletions()
            closeHistorySearch()
            if flags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
            didChangeText()
            return true
        }
        if TextShortcuts.perform(event, in: self, canEdit: true) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private static func withoutControls(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }))
    }

    override func paste(_ sender: Any?) {
        if isSearchingHistory {
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            let line = Self.withoutControls(text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))
            if !line.isEmpty { setSearchQuery((searchQuery ?? "") + line) }
            return
        }
        guard forwardsKeys else {
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            insertText(Self.withoutControls(lines), replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        onPaste?(text)
    }

    override func didChangeText() {
        super.didChangeText()
        if !applyingCompletion, !handlingKey { closeCompletions() }
        if !applyingHistory { navigator.reset() }
        highlight()
        onHeightChange?()
    }

    // MARK: Input method

    private static func plain(_ value: Any) -> String {
        (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
    }

    override func hasMarkedText() -> Bool { isDetached ? !detachedMarked.isEmpty : super.hasMarkedText() }

    override func markedRange() -> NSRange {
        guard isDetached else { return super.markedRange() }
        return detachedMarked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (detachedMarked as NSString).length)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard isDetached else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
        detachedMarked = Self.plain(string)
        if isSearchingHistory { onSearchChange?() }
    }

    override func unmarkText() {
        guard isDetached else {
            super.unmarkText()
            return
        }
        detachedMarked = ""
        if isSearchingHistory { onSearchChange?() }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard isDetached else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        detachedMarked = ""
        let text = Self.withoutControls(Self.plain(string))
        if isSearchingHistory {
            if text.isEmpty { onSearchChange?() } else { setSearchQuery((searchQuery ?? "") + text) }
        } else if !text.isEmpty {
            onKey?(.text(text), false)
        }
    }

    override func doCommand(by selector: Selector) {
        if hasMarkedText() {
            if isDetached {
                let pending = detachedMarked
                insertText(pending, replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                unmarkText()
            }
            return
        }
        guard !isDetached else { return }
        super.doCommand(by: selector)
    }

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(Theme.textTertiary),
        ]
        NSAttributedString(string: placeholder, attributes: attributes)
            .draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height))
    }
}
