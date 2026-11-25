import Foundation

public enum InputSender {
    public static func bytes(text: String, bracketedPaste: Bool) -> [UInt8] {
        var clean = BlockRerun.sanitized(text)
        while clean.last == "\n" { clean.removeLast() }
        var bytes = BlockRerun.clearLine
        if bracketedPaste {
            bytes += BlockRerun.pasteStart + Array(clean.utf8) + BlockRerun.pasteEnd
        } else {
            bytes += Array(clean.replacingOccurrences(of: "\n", with: "\r").replacingOccurrences(of: "\t", with: "\u{16}\t").utf8)
        }
        bytes.append(0x0D)
        return bytes
    }

    public static func pasteBytes(text: String, bracketedPaste: Bool) -> [UInt8] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let clean = BlockRerun.sanitized(lines).replacingOccurrences(of: "\n", with: "\r")
        guard !clean.isEmpty else { return [] }
        return bracketedPaste ? BlockRerun.pasteStart + Array(clean.utf8) + BlockRerun.pasteEnd : Array(clean.utf8)
    }
}
