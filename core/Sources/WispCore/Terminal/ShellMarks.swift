import Foundation

public enum ShellEvent: Equatable, Sendable {
    case promptStart
    case promptEnd
    case commandStart
    case commandEnd(exitCode: Int?)
    case directory(String)
    case historyFile(String)
    case command(String)
    case alternateScreen(Bool)
    case mouseTracking(Bool)
    case cleared(scrollback: Bool)
    case declined
}

public struct ScannedShellEvent: Equatable, Sendable {
    public let event: ShellEvent
    public let range: Range<Int>
    public let beganEarlier: Bool
}

public struct ShellMarkScanner: Sendable {
    public static let customCode = 6973
    private static let maxBody = 65_536
    private static let maxCSI = 32

    private enum State: Equatable {
        case ground
        case escape
        case csi
        case oscCode
        case oscBody
        case oscBodyEscape
        case oscSkip
        case oscSkipEscape
    }

    private var state = State.ground
    private var promptOpen = false
    private var code = 0
    private var codeDigits = 0
    private var body = [UInt8]()
    private var csi = [UInt8]()
    private var openedEarlier = false
    private var mouseModes = Set<Int>()
    private let nonce: [UInt8]
    public private(set) var pendingStart: Int?

    public init(nonce: String?) {
        self.nonce = Array((nonce ?? "").utf8)
    }

    public mutating func resetSequence() {
        state = .ground
        code = 0
        codeDigits = 0
        body.removeAll()
        csi.removeAll()
        openedEarlier = false
        pendingStart = nil
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
            case 0x5D:
                state = .oscCode
                code = 0
                codeDigits = 0
                body.removeAll(keepingCapacity: true)
            case 0x5B:
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
                return csiEvents(params: csi, final: byte)
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
            if byte == 0x3B {
                state = code == Self.customCode && !nonce.isEmpty ? .oscBody : .oscSkip
                return []
            }
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
            if byte == 0x5C { return finishOSC() }
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
        var event = markEvent(body: body)
        switch event {
        case .promptStart?:
            mouseModes.removeAll()
            promptOpen = true
        case .commandEnd?: mouseModes.removeAll()
        case .promptEnd?:
            if promptOpen { promptOpen = false } else { event = nil }
        default: break
        }
        return event.map { [$0] } ?? []
    }

    private func markEvent(body: [UInt8]) -> ShellEvent? {
        guard body.count > nonce.count, body[nonce.count] == 0x3B, body.starts(with: nonce) else { return nil }
        let mark = body[(nonce.count + 1)...]
        if mark.elementsEqual("A".utf8) { return .promptStart }
        if mark.elementsEqual("B".utf8) { return .promptEnd }
        if mark.elementsEqual("C".utf8) { return .commandStart }
        if mark.elementsEqual("declined".utf8) { return .declined }
        if mark.first == UInt8(ascii: "D"), mark.count == 1 || mark[mark.startIndex + 1] == 0x3B {
            let digits = mark.dropFirst(2).prefix { $0 >= 0x30 && $0 <= 0x39 }
            return .commandEnd(exitCode: digits.isEmpty ? nil : Int(String(decoding: digits, as: UTF8.self)))
        }
        if mark.starts(with: "cmd=".utf8) {
            return Self.decodeCommand(String(decoding: mark.dropFirst(4), as: UTF8.self)).map { .command($0) }
        }
        if mark.starts(with: "hist=".utf8) {
            return Self.decodeCommand(String(decoding: mark.dropFirst(5), as: UTF8.self)).flatMap { $0.isEmpty ? nil : .historyFile($0) }
        }
        if mark.starts(with: "cwd=".utf8) {
            return .directory(String(decoding: mark.dropFirst(4), as: UTF8.self))
        }
        return nil
    }

    public static func decodeCommand(_ encoded: String) -> String? {
        var text = encoded.filter { !$0.isWhitespace }
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private mutating func csiEvents(params: [UInt8], final: UInt8) -> [ShellEvent] {
        let text = String(decoding: params, as: UTF8.self)
        switch final {
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            guard text.hasPrefix("?") else { return [] }
            let modes = text.dropFirst().split(separator: ";").compactMap { Int($0) }
            let on = final == UInt8(ascii: "h")
            var events = [ShellEvent]()
            if modes.contains(where: { $0 == 47 || $0 == 1047 || $0 == 1049 }) { events.append(.alternateScreen(on)) }
            let tracking = modes.filter { $0 == 1000 || $0 == 1002 || $0 == 1003 }
            if !tracking.isEmpty {
                if on { mouseModes.formUnion(tracking) } else { mouseModes.subtract(tracking) }
                events.append(.mouseTracking(!mouseModes.isEmpty))
            }
            return events
        case UInt8(ascii: "J"):
            if text == "2" { return [.cleared(scrollback: false)] }
            if text == "3" { return [.cleared(scrollback: true)] }
            return []
        default:
            return []
        }
    }
}

public enum ShellStreamPiece: Equatable, Sendable {
    case bytes(Range<Int>)
    case headerRow
    case resetGrid
    case event(ShellEvent)
}

public struct ShellStreamCut: Equatable, Sendable {
    public var bytes: ArraySlice<UInt8>
    public var pieces: [ShellStreamPiece]
}

public struct ShellStream: Sendable {
    static let maxHeld = 256

    private let nonce: String?
    private let nativeBlocks: Bool
    private var scanner: ShellMarkScanner
    private var held = [UInt8]()
    private var sawCommand = false
    private var inAlternate = false

    public init(nonce: String?, nativeBlocks: Bool = false) {
        self.nonce = nonce
        self.nativeBlocks = nativeBlocks
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
            scanner.resetSequence()
        }
        var pieces = [ShellStreamPiece]()
        var fed = 0
        for item in found {
            if item.event == .promptStart, !nativeBlocks, !item.beganEarlier, sawCommand, !inAlternate {
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
            if nativeBlocks, item.event == .commandStart { pieces.append(.resetGrid) }
            pieces.append(.event(item.event))
        }
        if fed < end { pieces.append(.bytes(fed..<end)) }
        return ShellStreamCut(bytes: input, pieces: pieces)
    }
}
