import AppKit
import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    var placeholder: String
    var disabled: Bool
    var onSubmit: () -> Void

    @State private var height = ComposerTextView.lineHeight

    private var canSend: Bool {
        !disabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let sendSize: CGFloat = 30
    private static let verticalInset: CGFloat = 11
    private static let radius: CGFloat = 20

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $text, height: $height, disabled: disabled, onSubmit: submit)
                    .frame(height: height)
            }
            .padding(.vertical, Self.verticalInset)
            .padding(.leading, Theme.Space.l)

            Button(action: submit) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(CircleButtonStyle(kind: .accent, size: Self.sendSize))
            .disabled(!canSend)
            .help("Enviar (Enter)")
            .padding(5)
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
