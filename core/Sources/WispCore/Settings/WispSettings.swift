import Foundation

public struct ThemePreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let accent: HexColor
    public let accentText: HexColor
    public let userBubble: HexColor

    public static let defaultBackground = HexColor(0x111214)
    public static let defaultSurface = HexColor(0x1A1B1E)
    public static let defaultSurfaceHi = HexColor(0x232428)

    public static let lime = ThemePreset(id: "lime", name: "Lima", accent: HexColor(0xA3D65C), accentText: HexColor(0xC9F08A), userBubble: HexColor(0x3E4A2A))

    public static let all: [ThemePreset] = [
        lime,
        ThemePreset(id: "teal", name: "Turquesa", accent: HexColor(0x4FD1C5), accentText: HexColor(0x9AF0E6), userBubble: HexColor(0x22403E)),
        ThemePreset(id: "blue", name: "Azul", accent: HexColor(0x5B9DFF), accentText: HexColor(0xA9CBFF), userBubble: HexColor(0x26364F)),
        ThemePreset(id: "violet", name: "Violeta", accent: HexColor(0xA78BFA), accentText: HexColor(0xD3C4FF), userBubble: HexColor(0x3A3252)),
        ThemePreset(id: "pink", name: "Rosa", accent: HexColor(0xF472B6), accentText: HexColor(0xFBB6DA), userBubble: HexColor(0x4D2A3E)),
        ThemePreset(id: "orange", name: "Laranja", accent: HexColor(0xFB923C), accentText: HexColor(0xFDC79B), userBubble: HexColor(0x4D3424)),
        ThemePreset(id: "red", name: "Vermelho", accent: HexColor(0xF2555A), accentText: HexColor(0xFFA3A6), userBubble: HexColor(0x4D2829)),
        ThemePreset(id: "mono", name: "Mono", accent: HexColor(0xD4D4D8), accentText: HexColor(0xF4F4F5), userBubble: HexColor(0x3A3A3F)),
    ]

    public static func named(_ id: String) -> ThemePreset? {
        all.first { $0.id == id }
    }
}

public struct ThemeColors: Equatable, Sendable {
    public var accent: HexColor
    public var accentText: HexColor
    public var userBubble: HexColor
    public var background: HexColor
    public var surface: HexColor
    public var surfaceHi: HexColor

    public init(accent: HexColor, accentText: HexColor, userBubble: HexColor, background: HexColor, surface: HexColor, surfaceHi: HexColor) {
        self.accent = accent
        self.accentText = accentText
        self.userBubble = userBubble
        self.background = background
        self.surface = surface
        self.surfaceHi = surfaceHi
    }

    public init(preset: ThemePreset) {
        self.init(
            accent: preset.accent,
            accentText: preset.accentText,
            userBubble: preset.userBubble,
            background: ThemePreset.defaultBackground,
            surface: ThemePreset.defaultSurface,
            surfaceHi: ThemePreset.defaultSurfaceHi
        )
    }

    public init(custom: CustomTheme) {
        self.init(
            accent: custom.accent,
            accentText: custom.accent.mixed(with: .white, amount: Self.accentTextLift),
            userBubble: custom.surface.mixed(with: custom.accent, amount: Self.bubbleTint),
            background: custom.background,
            surface: custom.surface,
            surfaceHi: Self.raised(custom.surface)
        )
    }

    static let lightText = (primary: HexColor(0xF2F2F3), secondary: HexColor(0x9A9BA1), tertiary: HexColor(0x6B6C72))
    static let darkText = (primary: HexColor(0x141416), secondary: HexColor(0x55565B), tertiary: HexColor(0x7E7F85))
    public static let minimumTextContrast = 4.5

    private var textTokens: (primary: HexColor, secondary: HexColor, tertiary: HexColor) {
        let light = Self.lightText
        guard light.primary.contrastRatio(with: background) < Self.minimumTextContrast else { return light }
        return background.luminance > 0.18 ? Self.darkText : light
    }

    public var textPrimary: HexColor { textTokens.primary }
    public var textSecondary: HexColor { textTokens.secondary }
    public var textTertiary: HexColor { textTokens.tertiary }

    private static func raised(_ surface: HexColor) -> HexColor {
        surface.mixed(with: .white, amount: surfaceHiLift)
    }

    static let accentTextLift = 0.4
    static let bubbleTint = 0.26
    static let surfaceHiLift = 0.04
}

public struct CustomTheme: Codable, Equatable, Sendable {
    public var accent: HexColor
    public var background: HexColor
    public var surface: HexColor

    public init(accent: HexColor, background: HexColor, surface: HexColor) {
        self.accent = accent
        self.background = background
        self.surface = surface
    }
}

public enum DashboardTileID {
    public static let music = "music"
    public static let usage = "usage"
    public static let alerts = "alerts"
    public static let conversation = "conversation"

    public static let defaultOrder = [music, usage, alerts, conversation]

    public static func normalized(_ saved: [String]) -> [String] {
        var seen = Set<String>()
        let kept = saved.filter { defaultOrder.contains($0) && seen.insert($0).inserted }
        return kept + defaultOrder.filter { !seen.contains($0) }
    }
}

public struct WispSettings: Codable, Equatable, Sendable {
    public static let customTheme = "custom"

    public var theme: String
    public var custom: CustomTheme?
    public var dashboardOrder: [String] {
        didSet { dashboardOrder = DashboardTileID.normalized(dashboardOrder) }
    }
    public var clipboardCapture = true
    public var spotifyClientID = ""

    public init(theme: String = ThemePreset.lime.id, custom: CustomTheme? = nil, dashboardOrder: [String] = DashboardTileID.defaultOrder) {
        self.theme = theme
        self.custom = custom
        self.dashboardOrder = DashboardTileID.normalized(dashboardOrder)
    }

    private enum CodingKeys: String, CodingKey { case theme, custom, dashboardOrder, clipboardCapture, spotifyClientID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decode(String.self, forKey: .theme)
        custom = try container.decodeIfPresent(CustomTheme.self, forKey: .custom)
        dashboardOrder = DashboardTileID.normalized(try container.decodeIfPresent([String].self, forKey: .dashboardOrder) ?? [])
        clipboardCapture = try container.decodeIfPresent(Bool.self, forKey: .clipboardCapture) ?? true
        spotifyClientID = try container.decodeIfPresent(String.self, forKey: .spotifyClientID) ?? ""
    }

    public static let `default` = WispSettings()

    public var isCustom: Bool { theme == Self.customTheme && custom != nil }

    public var colors: ThemeColors {
        if theme == Self.customTheme, let custom { return ThemeColors(custom: custom) }
        return ThemeColors(preset: ThemePreset.named(theme) ?? .lime)
    }
}
