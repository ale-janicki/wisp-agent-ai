import Foundation

public struct HexColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(_ value: UInt32) {
        self.init(red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }

    public init?(_ text: String) {
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else {
            return nil
        }
        self.init(value)
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    public func mixed(with other: HexColor, amount: Double) -> HexColor {
        let t = min(1, max(0, amount))
        func blend(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded())
        }
        return HexColor(red: blend(red, other.red), green: blend(green, other.green), blue: blend(blue, other.blue))
    }

    public static let white = HexColor(0xFFFFFF)

    public var luminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let c = Double(channel) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrastRatio(with other: HexColor) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension HexColor: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = HexColor(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a #RRGGBB color: \(text)")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
