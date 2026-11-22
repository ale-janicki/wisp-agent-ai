import Foundation

public enum LZString {
    private static let base64Alphabet: [UInt16] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf16)
    private static let base64Values: [UInt16: Int] = {
        var values: [UInt16: Int] = [:]
        for (index, unit) in base64Alphabet.enumerated() { values[unit] = index }
        return values
    }()

    public static func compressToBase64(_ input: String) -> String {
        let encoded = compress(Array(input.utf16), bitsPerChar: 6) { base64Alphabet[$0] }
        let padding: [UInt16]
        switch encoded.count % 4 {
        case 1: padding = Array("===".utf16)
        case 2: padding = Array("==".utf16)
        case 3: padding = Array("=".utf16)
        default: padding = []
        }
        return String(decoding: encoded + padding, as: UTF16.self)
    }

    public enum DecompressError: Error, Equatable {
        case corrupted
        case tooLarge
    }

    public static let defaultMaxUnits = 25_000_000

    public static func decompressFromBase64(_ input: String) -> String? {
        try? decompressChecked(fromBase64: input)
    }

    public static func decompressChecked(fromBase64 input: String, maxUnits: Int = defaultMaxUnits) throws -> String {
        let units = Array(input.utf16)
        if units.isEmpty { throw DecompressError.corrupted }
        guard let result = try decompress(length: units.count, resetValue: 32, maxUnits: maxUnits, next: { index in
            index < units.count ? (base64Values[units[index]] ?? 0) : 0
        }) else { throw DecompressError.corrupted }
        return String(decoding: result, as: UTF16.self)
    }

    private struct BitWriter {
        let bitsPerChar: Int
        let output: (Int) -> UInt16
        var data: [UInt16] = []
        var value = 0
        var position = 0

        mutating func write(bit: Int) {
            value = (value << 1) | bit
            if position == bitsPerChar - 1 {
                position = 0
                data.append(output(value))
                value = 0
            } else {
                position += 1
            }
        }

        mutating func write(_ number: Int, bits: Int) {
            var remaining = number
            for _ in 0..<bits {
                write(bit: remaining & 1)
                remaining >>= 1
            }
        }

        mutating func flush() {
            while true {
                value <<= 1
                if position == bitsPerChar - 1 {
                    data.append(output(value))
                    break
                }
                position += 1
            }
        }
    }

    private static func compress(_ input: [UInt16], bitsPerChar: Int, output: @escaping (Int) -> UInt16) -> [UInt16] {
        var writer = BitWriter(bitsPerChar: bitsPerChar, output: output)
        var dictionary: [[UInt16]: Int] = [:]
        var toCreate: Set<[UInt16]> = []
        var w: [UInt16] = []
        var enlargeIn = 2
        var dictSize = 3
        var numBits = 2

        func emit(_ word: [UInt16]) {
            if toCreate.contains(word) {
                let unit = Int(word[0])
                if unit < 256 {
                    writer.write(0, bits: numBits)
                    writer.write(unit, bits: 8)
                } else {
                    writer.write(1, bits: numBits)
                    writer.write(unit, bits: 16)
                }
                enlargeIn -= 1
                if enlargeIn == 0 {
                    enlargeIn = 1 << numBits
                    numBits += 1
                }
                toCreate.remove(word)
            } else {
                writer.write(dictionary[word]!, bits: numBits)
            }
            enlargeIn -= 1
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
        }

        for unit in input {
            let c = [unit]
            if dictionary[c] == nil {
                dictionary[c] = dictSize
                dictSize += 1
                toCreate.insert(c)
            }
            let wc = w + c
            if dictionary[wc] != nil {
                w = wc
            } else {
                emit(w)
                dictionary[wc] = dictSize
                dictSize += 1
                w = c
            }
        }
        if !w.isEmpty { emit(w) }
        writer.write(2, bits: numBits)
        writer.flush()
        return writer.data
    }

    private static func decompress(length: Int, resetValue: Int, maxUnits: Int, next: (Int) -> Int) throws -> [UInt16]? {
        var dictionary: [[UInt16]] = [[0], [1], [2]]
        var enlargeIn = 4
        var numBits = 3
        var data = (value: next(0), position: resetValue, index: 1)

        func readBits(_ count: Int) -> Int {
            var bits = 0
            var power = 1
            let maxPower = 1 << count
            while power != maxPower {
                let bit = data.value & data.position
                data.position >>= 1
                if data.position == 0 {
                    data.position = resetValue
                    data.value = next(data.index)
                    data.index += 1
                }
                bits |= (bit > 0 ? 1 : 0) * power
                power <<= 1
            }
            return bits
        }

        let first = readBits(2)
        let firstUnit: UInt16
        switch first {
        case 0: firstUnit = UInt16(truncatingIfNeeded: readBits(8))
        case 1: firstUnit = UInt16(truncatingIfNeeded: readBits(16))
        default: return []
        }
        dictionary.append([firstUnit])
        var w: [UInt16] = [firstUnit]
        var result: [UInt16] = [firstUnit]
        var dictionaryUnits = 1
        var iterations = 0
        let maxIterations = length * 6 + 16

        while true {
            iterations += 1
            if iterations > maxIterations { throw DecompressError.corrupted }
            if data.index > length { return [] }
            var code = readBits(numBits)
            switch code {
            case 0:
                dictionary.append([UInt16(truncatingIfNeeded: readBits(8))])
                code = dictionary.count - 1
                enlargeIn -= 1
            case 1:
                dictionary.append([UInt16(truncatingIfNeeded: readBits(16))])
                code = dictionary.count - 1
                enlargeIn -= 1
            case 2:
                return result
            default:
                break
            }
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
            let entry: [UInt16]
            if code < dictionary.count {
                entry = dictionary[code]
            } else if code == dictionary.count {
                entry = w + [w[0]]
            } else {
                return nil
            }
            if result.count + entry.count > maxUnits || dictionaryUnits + w.count + 1 > maxUnits * 2 { throw DecompressError.tooLarge }
            result.append(contentsOf: entry)
            dictionaryUnits += w.count + 1
            dictionary.append(w + [entry[0]])
            enlargeIn -= 1
            w = entry
            if enlargeIn == 0 {
                enlargeIn = 1 << numBits
                numBits += 1
            }
        }
    }
}
