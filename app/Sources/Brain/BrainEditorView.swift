import AppKit
import SwiftUI
import WispCore

struct BrainEditorView: NSViewRepresentable {
    let id: UUID
    let text: String
    let revision: Int
    let jumpLine: Int?
    let jumpSeq: Int
    let locked: Bool
    var model: BrainModel

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let view = BrainTextView()
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        context.coordinator.view = view
        context.coordinator.replace(text: text, revision: revision)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.view?.isEditable = !locked
        coordinator.replace(text: text, revision: revision)
        if coordinator.lastJump != jumpSeq {
            coordinator.lastJump = jumpSeq
            if let jumpLine { coordinator.scroll(toLine: jumpLine) }
        }
        if let insert = model.pendingInsert {
            coordinator.view?.insertText(insert, replacementRange: coordinator.view?.selectedRange() ?? NSRange(location: 0, length: 0))
            DispatchQueue.main.async { model.pendingInsert = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BrainEditorView
        weak var view: BrainTextView?
        var revision = -1
        var lastJump = 0
        private var highlightTask: Task<Void, Never>?
        private var completing = false
        private var applying = false

        static let fullLimit = 150_000
        static let window = 20_000

        init(_ parent: BrainEditorView) {
            self.parent = parent
        }

        func replace(text: String, revision newRevision: Int) {
            guard let view, newRevision != revision else { return }
            revision = newRevision
            applying = true
            view.string = text
            applying = false
            highlight(visibleOnly: true)
        }

        func textDidChange(_ notification: Notification) {
            guard let view, !applying else { return }
            parent.model.edit(parent.id, text: view.string)
            highlightTask?.cancel()
            let length = (view.string as NSString).length
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(length > 40_000 ? 250 : 60))
                guard !Task.isCancelled else { return }
                self?.highlight(visibleOnly: true)
            }
            triggerCompletion()
        }

        @objc func scrolled() {
            guard let view, (view.string as NSString).length > Self.fullLimit else { return }
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self?.highlight(visibleOnly: true)
            }
        }

        func scroll(toLine line: Int) {
            guard let view else { return }
            let ns = view.string as NSString
            var location = 0
            var current = 0
            while current < line, location < ns.length {
                location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
                current += 1
            }
            let range = NSRange(location: min(location, ns.length), length: 0)
            view.setSelectedRange(range)
            view.scrollRangeToVisible(NSRange(location: range.location, length: min(200, ns.length - range.location)))
        }

        private func triggerCompletion() {
            guard let view, !completing else { return }
            let cursor = view.selectedRange().location
            guard let context = BrainCompletion.context(in: view.string, cursor: cursor), context.kind == .link || !context.query.isEmpty else { return }
            completing = true
            DispatchQueue.main.async { [weak self] in
                self?.view?.complete(nil)
                self?.completing = false
            }
        }

        func completions(for context: BrainCompletionContext) -> [String] {
            switch context.kind {
            case .link:
                parent.model.switcherResultsForCompletion(context.query).map { BrainCompletion.linkText(for: $0, catalog: parent.model.catalog) }
            case .tag:
                BrainCompletion.tags(context.query, in: parent.model.tagCounts)
            }
        }

        func highlight(visibleOnly: Bool) {
            guard let view, let storage = view.textStorage else { return }
            let ns = view.string as NSString
            guard ns.length > 0 else { return }
            var region = NSRange(location: 0, length: ns.length)
            if ns.length > Self.fullLimit, visibleOnly, let layout = view.layoutManager, let container = view.textContainer {
                let visible = view.visibleRect
                let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
                let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let start = max(0, characters.location - Self.window)
                let end = min(ns.length, NSMaxRange(characters) + Self.window)
                region = ns.paragraphRange(for: NSRange(location: start, length: end - start))
            }
            let slice = ns.substring(with: region)
            let spans = BrainSyntax.spans(in: slice)
            applying = true
            storage.beginEditing()
            storage.setAttributes(Self.base, range: region)
            for span in spans {
                let range = NSRange(location: region.location + span.range.location, length: span.range.length)
                guard NSMaxRange(range) <= ns.length else { continue }
                Self.apply(span.kind, to: storage, range: range)
            }
            storage.endEditing()
            applying = false
            view.typingAttributes = Self.base
        }

        static var base: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(Theme.textPrimary)]
        }

        private static func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> NSFont {
            var font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            return font
        }

        private static func apply(_ kind: BrainSyntaxSpan.Kind, to storage: NSTextStorage, range: NSRange) {
            switch kind {
            case .heading(let level):
                storage.addAttributes([.font: font(CGFloat(max(13, 20 - level * 2)), bold: true)], range: range)
            case .bold: storage.addAttribute(.font, value: font(13, bold: true), range: range)
            case .italic: storage.addAttribute(.font, value: font(13, italic: true), range: range)
            case .strike: storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .highlight: storage.addAttribute(.backgroundColor, value: NSColor(Theme.busy).withAlphaComponent(0.3), range: range)
            case .code, .codeBlock:
                storage.addAttributes([.font: font(12, mono: true), .backgroundColor: NSColor(Theme.surfaceHi)], range: range)
            case .fence: storage.addAttribute(.foregroundColor, value: NSColor(Theme.textTertiary), range: range)
            case .wikilink, .link: storage.addAttribute(.foregroundColor, value: NSColor(Theme.accent), range: range)
            case .tag: storage.addAttribute(.foregroundColor, value: NSColor(Theme.accentTeal), range: range)
            case .quote: storage.addAttribute(.foregroundColor, value: NSColor(Theme.textSecondary), range: range)
            case .marker: storage.addAttribute(.foregroundColor, value: NSColor(Theme.accent), range: range)
            case .comment: storage.addAttribute(.foregroundColor, value: NSColor(Theme.textTertiary), range: range)
            case .frontmatter:
                storage.addAttributes([.font: font(12, mono: true), .foregroundColor: NSColor(Theme.textTertiary)], range: range)
            }
        }
    }
}

final class BrainTextView: NSTextView {
    weak var coordinator: BrainEditorView.Coordinator?
    private var linkContext: BrainCompletionContext?

    override var rangeForUserCompletion: NSRange {
        guard let context = BrainCompletion.context(in: string, cursor: selectedRange().location) else { return NSRange(location: NSNotFound, length: 0) }
        linkContext = context
        return context.range
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard let context = BrainCompletion.context(in: string, cursor: selectedRange().location), let coordinator else { return nil }
        index.pointee = 0
        let items = MainActor.assumeIsolated { coordinator.completions(for: context) }
        return items.isEmpty ? nil : items
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        guard flag, movement != NSCancelTextMovement, linkContext?.kind == .link else { return }
        let ns = string as NSString
        let end = selectedRange().location
        if ns.length < end + 2 || ns.substring(with: NSRange(location: end, length: 2)) != "]]" {
            insertText("]]", replacementRange: selectedRange())
        } else {
            setSelectedRange(NSRange(location: end + 2, length: 0))
        }
    }
}
