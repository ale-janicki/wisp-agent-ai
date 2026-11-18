import AppKit
import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    var placeholder: String
    var disabled: Bool
    var attachments: [URL] = []
    var notice: String?
    var onAttach: ([URL]) -> Void = { _ in }
    var onRemove: (URL) -> Void = { _ in }
    var onSubmit: () -> Void

    @State private var height = ComposerTextView.lineHeight

    private var canSend: Bool {
        !disabled && (!attachments.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private static let sendSize: CGFloat = 30
    private static let verticalInset: CGFloat = 11
    private static let radius: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                PendingAttachmentsBar(urls: attachments, onRemove: onRemove)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.s)
            }
            if let notice {
                Text(notice)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.top, Theme.Space.s)
            }
            inputRow
        }
        .background {
            RoundedRectangle(cornerRadius: Self.radius, style: .circular)
                .fill(Theme.surfaceHi)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .circular)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        }
        .opacity(disabled ? 0.6 : 1)
        .animation(.easeOut(duration: 0.15), value: height)
        .animation(.easeOut(duration: 0.15), value: attachments)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            Button(action: pick) {
                Image(systemName: "paperclip")
            }
            .buttonStyle(CircleButtonStyle(kind: .plain, size: Self.sendSize))
            .disabled(disabled)
            .help("Anexar foto ou arquivo")
            .padding([.leading, .vertical], 5)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $text, height: $height, disabled: disabled, onSubmit: submit, onPasteFiles: onAttach)
                    .frame(height: height)
            }
            .padding(.vertical, Self.verticalInset)

            Button(action: submit) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(CircleButtonStyle(kind: .accent, size: Self.sendSize))
            .disabled(!canSend)
            .help("Enviar (Enter)")
            .padding(5)
        }
    }

    private func pick() {
        guard !disabled, let urls = AttachmentPicker.choose() else { return }
        onAttach(urls)
    }

    private func submit() {
        guard canSend else { return }
        onSubmit()
    }
}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var disabled: Bool
    var onSubmit: () -> Void
    var onPasteFiles: ([URL]) -> Void = { _ in }

    static let font = NSFont.systemFont(ofSize: 13)
    static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
    static let maxLines: CGFloat = 5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none

        let textView = ComposerNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.textColor = NSColor(Theme.textPrimary)
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.3)]
        textView.string = text
        let coordinator = context.coordinator
        textView.onPasteFiles = { [weak coordinator] urls in coordinator?.parent.onPasteFiles(urls) }
        textView.onWidthChange = { [weak coordinator] in
            Task { @MainActor in coordinator?.recalculateHeight() }
        }
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = !disabled
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            Task { @MainActor in context.coordinator.recalculateHeight() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalculateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        func recalculateHeight() {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = ceil(layout.usedRect(for: container).height)
            let line = ComposerTextView.lineHeight
            let next = min(max(used, line), line * ComposerTextView.maxLines)
            if abs(next - parent.height) > 0.5 { parent.height = next }
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var onWidthChange: (() -> Void)?
    var onPasteFiles: (@MainActor ([URL]) -> Void)?

    /// ⌘V of an image or of files copied in Finder attaches them; text pastes as before.
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        let hasText = board.availableType(from: [.string]) != nil
        let hasFiles = board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if let onPasteFiles, hasFiles || !hasText, AttachmentPicker.pasted(from: board, completion: onPasteFiles) { return }
        super.paste(sender)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?() }
    }
}
