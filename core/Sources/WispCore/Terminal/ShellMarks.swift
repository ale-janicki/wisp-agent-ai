import Foundation

/// What the shell integration (and the terminal itself) says in the byte stream, reduced to what the blocks need. The marks of the
/// integration are Wisp's own OSC (`OSC 6973;<nonce>;…`) and count only with the session's nonce: a program that prints look-alike
/// marks (a file, a remote host, plain OSC 133) makes no block. The nonce never reaches the shell's children.
public enum ShellEvent: Equatable, Sendable {
    /// `…;A`: a prompt starts.
    case promptStart
    /// `…;C`: the command starts running.
    case commandStart
    /// `…;D;<code>`: the command ended. Nil when the shell sent no code.
    case commandEnd(exitCode: Int?)
    /// `…;cwd=<url>`: the shell's directory, as the report it sent (`file://host/path`).
    case directory(String)
    /// `…;cmd=<base64>`: the text of the command about to run.
    case command(String)
    /// The alternate screen (vim, htop, less) was entered or left.
    case alternateScreen(Bool)
    /// The screen (ED 2) or the screen and its scrollback (ED 3) was erased.
    case cleared(scrollback: Bool)
    /// `…;declined`: the hooks did not go in (bash with a DEBUG trap of its own). No blocks come; the folder still comes as `cwd=`.
    case declined
}

/// One event found in the bytes handed to `ShellMarkScanner.scan`, with where its sequence sits in them.
public struct ScannedShellEvent: Equatable, Sendable {
    public let event: ShellEvent
    /// Offsets from the start of the scanned bytes. `range.upperBound` is just after the sequence; `range.lowerBound` is 0 and
    /// `beganEarlier` is true when the sequence began in an earlier read.
    public let range: Range<Int>
    public let beganEarlier: Bool
}

/// Finds the sequences the blocks depend on in the raw stream a pty delivers, however the reads cut it. It keeps only the state of
/// a sequence still open at the end of a read; it never keeps the bytes that are not part of one. Without a nonce no mark counts.
public struct ShellMarkScanner: Sendable {
    public static let customCode = 6973
    private static let maxBody = 65_536
    private static let maxCSI = 32

    private enum State: Equatable {
        case ground
        case escape
        case csi
        /// After `ESC ]`, reading the decimal code up to `;`.
        case oscCode
        case oscBody
        case oscBodyEscape
        case oscSkip
        case oscSkipEscape
    }

    private var state = State.ground
    private var code = 0
    private var codeDigits = 0
    private var body = [UInt8]()
    private var csi = [UInt8]()
    private var openedEarlier = false
    private let nonce: [UInt8]
    /// Where, in the bytes of the last scan, a sequence still open at its end began; nil when none is open or it began earlier.
    public private(set) var pendingStart: Int?

    public init(nonce: String?) {
        self.nonce = Array((nonce ?? "").utf8)
    }

    public mutating func scan(_ bytes: ArraySlice<UInt8>) -> [ScannedShellEvent] {
        var found = [ScannedShellEvent]()
        openedEarlier = state != .ground
        var start = 0
        defer { pendingStart = state == .ground || openedEarlier ? nil : start }
        bytes.withUnsafeBufferPointer { buffer in
            var index = 0
            let count = buffer.count
            while index < count {
                if state == .ground {
                    guard let base = buffer.baseAddress,
                          let hit = memchr(base + index, 0x1B, count - index) else { return }
                    start = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                    state = .escape
                    index = start + 1
                    continue
                }
                let byte = buffer[index]
                index += 1
                for event in step(byte) {
                    found.append(ScannedShellEvent(
                        event: event, range: (openedEarlier ? 0 : start)..<index, beganEarlier: openedEarlier))
                }
                if state == .ground { openedEarlier = false }
            }
        }
        return found
    }

    private mutating func step(_ byte: UInt8) -> [ShellEvent] {
        switch state {
        case .ground:
            return []
        case .escape:
            switch byte {
            case 0x5D: // ]
                state = .oscCode
                code = 0
                codeDigits = 0
                body.removeAll(keepingCapacity: true)
            case 0x5B: // [
                state = .csi
                csi.removeAll(keepingCapacity: true)
            case 0x1B:
                break
            default:
                state = .ground
            }
            return []
        case .csi:
            if byte >= 0x40 && byte <= 0x7E {
                state = .ground
                return Self.csiEvents(params: csi, final: byte)
            }
            if byte == 0x1B {
                state = .escape
                return []
            }
            if byte < 0x20 || byte > 0x7E || csi.count >= Self.maxCSI {
                state = .ground
                return []
            }
            csi.append(byte)
            return []
        case .oscCode:
            if byte >= 0x30 && byte <= 0x39, codeDigits < 5 {
                code = code * 10 + Int(byte - 0x30)
                codeDigits += 1
                return []
            }
            if byte == 0x3B { // ;
                state = code == Self.customCode && !nonce.isEmpty ? .oscBody : .oscSkip
                return []
            }
            // A code with no body is not a mark.
            state = byte == 0x1B ? .oscSkipEscape : .ground
            return []
        case .oscBody:
            if byte == 0x07 { return finishOSC() }
            if byte == 0x1B { state = .oscBodyEscape; return [] }
            if byte == 0x18 || byte == 0x1A { state = .ground; return [] }
            if body.count >= Self.maxBody { state = .oscSkip; body.removeAll(); return [] }
            body.append(byte)
            return []
        case .oscBodyEscape:
            if byte == 0x5C { return finishOSC() } // ESC \
            state = byte == 0x5B || byte == 0x5D ? .escape : .ground
            return byte == 0x5B || byte == 0x5D ? step(byte) : []
        case .oscSkip:
            if byte == 0x07 || byte == 0x18 || byte == 0x1A { state = .ground } else if byte == 0x1B { state = .oscSkipEscape }
            return []
        case .oscSkipEscape:
            if byte == 0x5C { state = .ground } else { state = byte == 0x5B || byte == 0x5D ? .escape : .oscSkip }
            return byte == 0x5B || byte == 0x5D ? step(byte) : []
        }
    }

    private mutating func finishOSC() -> [ShellEvent] {
        state = .ground
        return markEvent(body: body).map { [$0] } ?? []
    }

    /// `<nonce>;<mark>`: a body without the session's nonce, or with another one, is nothing.
    private func markEvent(body: [UInt8]) -> ShellEvent? {
        guard body.count > nonce.count, body[nonce.count] == 0x3B, body.starts(with: nonce) else { return nil }
        let mark = body[(nonce.count + 1)...]
        if mark.elementsEqual("A".utf8) { return .promptStart }
        if mark.elementsEqual("C".utf8) { return .commandStart }
        if mark.elementsEqual("declined".utf8) { return .declined }
        if mark.first == UInt8(ascii: "D"), mark.count == 1 || mark[mark.startIndex + 1] == 0x3B {
            let digits = mark.dropFirst(2).prefix { $0 >= 0x30 && $0 <= 0x39 }
            return .commandEnd(exitCode: digits.isEmpty ? nil : Int(String(decoding: digits, as: UTF8.self)))
        }
        if mark.starts(with: "cmd=".utf8) {
            return Self.decodeCommand(String(decoding: mark.dropFirst(4), as: UTF8.self)).map { .command($0) }
        }
        if mark.starts(with: "cwd=".utf8) {
            return .directory(String(decoding: mark.dropFirst(4), as: UTF8.self))
        }
        return nil
    }

    /// The command text the shell sent, base64 with or without padding.
    public static func decodeCommand(_ encoded: String) -> String? {
        var text = encoded.filter { !$0.isWhitespace }
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func csiEvents(params: [UInt8], final: UInt8) -> [ShellEvent] {
        let text = String(decoding: params, as: UTF8.self)
        switch final {
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            guard text.hasPrefix("?") else { return [] }
            let modes = text.dropFirst().split(separator: ";").compactMap { Int($0) }
            guard modes.contains(where: { $0 == 47 || $0 == 1047 || $0 == 1049 }) else { return [] }
            return [.alternateScreen(final == UInt8(ascii: "h"))]
        case UInt8(ascii: "J"):
            if text == "2" { return [.cleared(scrollback: false)] }
            if text == "3" { return [.cleared(scrollback: true)] }
            return []
        default:
            return []
        }
    }
}

/// What to do with one read of the pty: feed these bytes, put the blank header row here, report this mark. Pure, so what reaches the
/// terminal is decided (and tested) apart from the terminal. Only a mark with the session's nonce adds a row.
public enum ShellStreamPiece: Equatable, Sendable {
    /// Offsets into `ShellStreamCut.bytes`.
    case bytes(Range<Int>)
    /// One blank row above a prompt, where its block's header sits.
    case headerRow
    /// The mark, reported once the bytes before it and the sequence itself are fed.
    case event(ShellEvent)
}

/// The bytes the pieces point into: the read, after what an earlier read held back.
public struct ShellStreamCut: Equatable, Sendable {
    public var bytes: ArraySlice<UInt8>
    public var pieces: [ShellStreamPiece]
}

/// A sequence a read cut in two is held back (it draws nothing until it ends anyway) and scanned whole with the next read, so a
/// prompt mark split across reads still gets its header row. A long one (a command text) is not held; it is fed as it comes.
public struct ShellStream: Sendable {
    static let maxHeld = 256

    private let nonce: String?
    private var scanner: ShellMarkScanner
    private var held = [UInt8]()
    private var sawCommand = false
    private var inAlternate = false

    public init(nonce: String?) {
        self.nonce = nonce
        scanner = ShellMarkScanner(nonce: nonce)
    }

    public mutating func cut(_ read: ArraySlice<UInt8>) -> ShellStreamCut {
        let input = held.isEmpty ? read : ArraySlice(held + read)
        held.removeAll()
        guard !input.isEmpty else { return ShellStreamCut(bytes: input, pieces: []) }
        let base = input.startIndex
        let found = scanner.scan(input)
        var end = input.count
        if let pending = scanner.pendingStart, input.count - pending <= Self.maxHeld {
            held = Array(input[(base + pending)...])
            end = pending
            scanner = ShellMarkScanner(nonce: nonce)
        }
        var pieces = [ShellStreamPiece]()
        var fed = 0
        for item in found {
            if item.event == .promptStart, !item.beganEarlier, sawCommand, !inAlternate {
                if item.range.lowerBound > fed { pieces.append(.bytes(fed..<item.range.lowerBound)) }
                fed = item.range.lowerBound
                pieces.append(.headerRow)
            }
            if item.range.upperBound > fed { pieces.append(.bytes(fed..<item.range.upperBound)) }
            fed = max(fed, item.range.upperBound)
            switch item.event {
            case .commandStart: sawCommand = true
            case .alternateScreen(let on): inAlternate = on
            default: break
            }
            pieces.append(.event(item.event))
        }
        if fed < end { pieces.append(.bytes(fed..<end)) }
        return ShellStreamCut(bytes: input, pieces: pieces)
    }
}
