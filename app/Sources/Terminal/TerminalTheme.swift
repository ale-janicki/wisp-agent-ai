import AppKit
import SwiftTerm
import WispCore

/// The Wisp theme as a terminal's colors: background, text and caret from the theme, and a 16-color palette picked for a dark ground.
@MainActor
enum TerminalTheme {
    static let compactFontSize: CGFloat = 12
    static let windowFontSize: CGFloat = 13

    /// Normal then bright, in ANSI order: black, red, green, yellow, blue, magenta, cyan, white.
    private static let palette: [UInt32] = [
        0x4B5263, 0xF2555A, 0x5BD66E, 0xF5B83D, 0x61AFEF, 0xC678DD, 0x4FD1C5, 0xC9CDD6,
        0x7A8294, 0xFF7B80, 0x86E895, 0xFFD068, 0x8CC8FF, 0xDDA0F0, 0x7FE8DD, 0xFFFFFF,
    ]

    private static func font(_ size: CGFloat) -> NSFont { NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }

    static func apply(to view: TerminalView, colors: ThemeColors, fontSize: CGFloat) {
        view.installColors(palette.map {
            SwiftTerm.Color(red8: UInt16(($0 >> 16) & 0xFF), green8: UInt16(($0 >> 8) & 0xFF), blue8: UInt16($0 & 0xFF))
        })
        view.nativeBackgroundColor = ns(colors.background)
        view.nativeForegroundColor = ns(colors.textPrimary)
        view.caretColor = ns(colors.accent)
        view.selectedTextBackgroundColor = ns(colors.accent).withAlphaComponent(0.35)
        if view.font.pointSize != fontSize { view.font = font(fontSize) }
    }

    private static func ns(_ color: HexColor) -> NSColor {
        NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
    }
}
