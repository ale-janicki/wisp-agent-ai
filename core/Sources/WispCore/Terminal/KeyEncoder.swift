import Foundation

public enum TerminalKey: Equatable, Sendable {
    case text(String)
    case enter
    case backspace
    case tab
    case escape
    case up, down, left, right
}

public enum KeyEncoder {
    public static func bytes(_ key: TerminalKey, control: Bool = false, applicationCursor: Bool = false) -> [UInt8] {
        switch key {
        case .text(let text):
            if control, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first, let code = controlCode(scalar) {
                return [code]
            }
            return Array(text.utf8)
        case .enter: return [0x0D]
        case .backspace: return [0x7F]
        case .tab: return [0x09]
        case .escape: return [0x1B]
        case .up: return arrow("A", applicationCursor)
        case .down: return arrow("B", applicationCursor)
        case .right: return arrow("C", applicationCursor)
        case .left: return arrow("D", applicationCursor)
        }
    }

    private static func arrow(_ letter: Character, _ application: Bool) -> [UInt8] {
        Array("\u{1B}\(application ? "O" : "[")\(letter)".utf8)
    }

    private static func controlCode(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x61...0x7A: return UInt8(scalar.value - 0x60)
        case 0x41...0x5A: return UInt8(scalar.value - 0x40)
        case 0x40, 0x20: return 0x00
        case 0x5B...0x5F: return UInt8(scalar.value - 0x40)
        case 0x3F: return 0x7F
        default: return nil
        }
    }
}
