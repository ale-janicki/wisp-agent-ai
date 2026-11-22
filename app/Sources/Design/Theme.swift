import SwiftUI
import WispCore

@MainActor
enum Theme {
    // MARK: Colors (sRGB)

    private static var colors: ThemeColors { AppSettings.shared.colors }

    static var bg: Color { Color(colors.background) }
    static var surface: Color { Color(colors.surface) }
    static var surfaceHi: Color { Color(colors.surfaceHi) }
    static let stroke = Color.white.opacity(0.06)
    static let onAccent = Color.white
    static let avatarSheen = Color.white.opacity(0.35)
    static let highlight = Color.white.opacity(0.05)
    static var textPrimary: Color { Color(colors.textPrimary) }
    static var textSecondary: Color { Color(colors.textSecondary) }
    static var textTertiary: Color { Color(colors.textTertiary) }

    static var accent: Color { Color(colors.accent) }
    static let accentTeal = Color(hex: 0x4FD1C5)
    static var accentFill: Color { accent.opacity(0.18) }
    static var accentText: Color { Color(colors.accentText) }
    static var userBubble: Color { Color(colors.userBubble) }

    static let ok = Color(hex: 0x5BD66E)
    static let busy = Color(hex: 0xF5B83D)
    static let error = Color(hex: 0xF2555A)

    static let notch = Color.black

    // MARK: Type

    enum Font {
        static let greeting = SwiftUI.Font.system(size: 26, weight: .bold)
        static let heading = SwiftUI.Font.system(size: 22, weight: .bold)
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyMedium = SwiftUI.Font.system(size: 13, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        static let captionMono = SwiftUI.Font.system(size: 11, weight: .medium).monospacedDigit()
        static let tool = SwiftUI.Font.system(size: 11, design: .monospaced)
    }

    // MARK: Shape

    enum Radius {
        static let panel: CGFloat = 26
        static let pill: CGFloat = 14
        static let pillShoulder: CGFloat = 8
        static let card: CGFloat = 18
        static let bubble: CGFloat = 14
        static let nav: CGFloat = 12
        static let artwork: CGFloat = 10
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    enum Control {
        static let height: CGFloat = 32
        static let compactHeight: CGFloat = 24
    }

    enum Layout {
        static let sidebarWidth: CGFloat = 200
        static let panelPadding: CGFloat = 16
        static let cardGap: CGFloat = 12
        static let rowHeight: CGFloat = 32
    }

    enum Graph {
        static let palette: [Color] = [
            Color(hex: 0xA3D65C), Color(hex: 0x4FD1C5), Color(hex: 0x60A5FA), Color(hex: 0xF5B83D),
            Color(hex: 0xC084FC), Color(hex: 0xF472B6), Color(hex: 0xFB923C), Color(hex: 0x94A3B8),
        ]
        static let other = Color(hex: 0x6B6C72)
        static let ghost = Color(hex: 0x45464B)
        static let edge = Color.white.opacity(0.09)
        static let well = Color.black.opacity(0.22)
    }
}

extension Color {
    init(_ color: HexColor) {
        self.init(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
    }

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension StatusColor {
    @MainActor var color: Color {
        switch self {
        case .ok: Theme.ok
        case .busy: Theme.busy
        case .error: Theme.error
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
    }
}

struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.nav

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
            .shadow(color: Theme.notch.opacity(0.35), radius: 14, y: 6)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
    func glass(cornerRadius: CGFloat = Theme.Radius.nav) -> some View { modifier(GlassBackground(cornerRadius: cornerRadius)) }
}

struct CircleButtonStyle: ButtonStyle {
    enum Kind { case plain, filled, accent }

    var kind: Kind = .plain
    var size: CGFloat = Theme.Control.height

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .circleChrome(kind: kind, size: size, pressed: configuration.isPressed)
    }
}

private struct CircleChrome: ViewModifier {
    let kind: CircleButtonStyle.Kind
    let size: CGFloat
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .contentShape(Circle())
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .onHover { hovering = $0 }
            .pointerStyle(isEnabled ? .link : nil)
    }

    private var foreground: Color {
        switch kind {
        case .plain: isEnabled ? Theme.textPrimary : Theme.textTertiary
        case .filled: Theme.bg
        case .accent: isEnabled ? Theme.bg : Theme.accent.opacity(0.45)
        }
    }

    private var fill: Color {
        switch kind {
        case .plain: hovering && isEnabled ? Theme.surfaceHi.opacity(1) : Theme.surfaceHi.opacity(0.7)
        case .filled: hovering ? Theme.textPrimary : .white
        case .accent: isEnabled ? (hovering ? Theme.accentText : Theme.accent) : Theme.accentFill
        }
    }
}

extension View {
    fileprivate func circleChrome(kind: CircleButtonStyle.Kind, size: CGFloat, pressed: Bool) -> some View {
        modifier(CircleChrome(kind: kind, size: size, pressed: pressed))
    }
}

struct IconMenu<Items: View>: View {
    let systemImage: String
    let help: String
    var compact = false
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            Image(systemName: systemImage)
                .circleChrome(kind: .plain, size: compact ? Theme.Control.compactHeight : Theme.Control.height, pressed: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

struct RowButtonStyle: ButtonStyle {
    enum Highlight { case none, accent, subtle }

    var highlight: Highlight = .none
    var height: CGFloat = Theme.Layout.rowHeight
    var hovered: Bool?

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, highlight: highlight, height: height, hovered: hovered)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let highlight: RowButtonStyle.Highlight
    let height: CGFloat
    let hovered: Bool?
    @State private var hovering = false

    private var fill: Color {
        switch highlight {
        case .accent: Theme.accentFill
        case .subtle: Theme.surfaceHi
        case .none: (hovered ?? hovering) ? Theme.surfaceHi.opacity(0.7) : .clear
        }
    }

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous)
                    .fill(fill)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.nav, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { hovering = $0 }
            .pointerStyle(.link)
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case accent, error, ghost }

    enum Size { case regular, compact }

    var kind: Kind = .accent
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .capsuleChrome(kind: kind, size: size, pressed: configuration.isPressed)
    }
}

private struct CapsuleChrome: ViewModifier {
    let kind: CapsuleButtonStyle.Kind
    let size: CapsuleButtonStyle.Size
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(size == .compact ? Theme.Font.caption : Theme.Font.bodyMedium)
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .compact ? Theme.Space.m : Theme.Space.l)
            .frame(height: size == .compact ? Theme.Control.compactHeight : Theme.Control.height)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .opacity(pressed ? 0.85 : 1)
            .onHover { hovering = $0 }
            .pointerStyle(isEnabled ? .link : nil)
    }

    private var foreground: Color {
        switch kind {
        case .accent: isEnabled ? Theme.bg : Theme.textTertiary
        case .error, .ghost: isEnabled ? Theme.textPrimary : Theme.textTertiary
        }
    }

    private var fill: Color {
        switch kind {
        case .accent: isEnabled ? (hovering ? Theme.accentText : Theme.accent) : Theme.accentFill
        case .error: Theme.error.opacity(hovering ? 0.9 : 0.75)
        case .ghost: hovering && isEnabled ? Theme.surfaceHi : Theme.surfaceHi.opacity(0.6)
        }
    }
}

extension View {
    fileprivate func capsuleChrome(kind: CapsuleButtonStyle.Kind, size: CapsuleButtonStyle.Size, pressed: Bool) -> some View {
        modifier(CapsuleChrome(kind: kind, size: size, pressed: pressed))
    }
}

struct CapsuleMenu<Items: View>: View {
    let title: String
    let help: String
    var size: CapsuleButtonStyle.Size = .regular
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            HStack(spacing: Theme.Space.xs) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .fixedSize()
            .capsuleChrome(kind: .ghost, size: size, pressed: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}
