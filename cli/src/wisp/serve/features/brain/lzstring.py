from __future__ import annotations

import struct

ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
VALUES = {c: i for i, c in enumerate(ALPHABET)}
MAX_UNITS = 25_000_000


class Corrupted(ValueError):
    pass


class TooLarge(ValueError):
    pass


def _units(text: str) -> str:
    data = text.encode("utf-16-le", "surrogatepass")
    return "".join(map(chr, struct.unpack(f"<{len(data) // 2}H", data)))


def _text(units: str) -> str:
    return units.encode("utf-16-le", "surrogatepass").decode("utf-16-le", "replace")


class _Writer:
    def __init__(self, bits_per_char: int):
        self.bits_per_char = bits_per_char
        self.out: list[str] = []
        self.value = 0
        self.position = 0

    def bit(self, bit: int) -> None:
        self.value = (self.value << 1) | bit
        if self.position == self.bits_per_char - 1:
            self.position = 0
            self.out.append(ALPHABET[self.value])
            self.value = 0
        else:
            self.position += 1

    def number(self, number: int, bits: int) -> None:
        for _ in range(bits):
            self.bit(number & 1)
            number >>= 1

    def flush(self) -> None:
        while True:
            self.value <<= 1
            if self.position == self.bits_per_char - 1:
                self.out.append(ALPHABET[self.value])
                return
            self.position += 1


def compress_to_base64(text: str) -> str:
    writer = _Writer(6)
    dictionary: dict[str, int] = {}
    to_create: set[str] = set()
    w = ""
    enlarge_in, dict_size, num_bits = 2, 3, 2

    def tick() -> None:
        nonlocal enlarge_in, num_bits
        enlarge_in -= 1
        if enlarge_in == 0:
            enlarge_in = 1 << num_bits
            num_bits += 1

    def emit(word: str) -> None:
        if word in to_create:
            unit = ord(word[0])
            if unit < 256:
                writer.number(0, num_bits)
                writer.number(unit, 8)
            else:
                writer.number(1, num_bits)
                writer.number(unit, 16)
            tick()
            to_create.discard(word)
        else:
            writer.number(dictionary[word], num_bits)
        tick()

    for c in _units(text):
        if c not in dictionary:
            dictionary[c] = dict_size
            dict_size += 1
            to_create.add(c)
        wc = w + c
        if wc in dictionary:
            w = wc
        else:
            emit(w)
            dictionary[wc] = dict_size
            dict_size += 1
            w = c
    if w:
        emit(w)
    writer.number(2, num_bits)
    writer.flush()
    encoded = "".join(writer.out)
    return encoded + {1: "===", 2: "==", 3: "="}.get(len(encoded) % 4, "")


def decompress_units(data: str, max_units: int = MAX_UNITS) -> str:
    if not data:
        raise Corrupted("empty")
    length = len(data)

    def nxt(index: int) -> int:
        return VALUES.get(data[index], 0) if index < length else 0

    reset = 32
    dictionary: list[str] = ["\0", "\1", "\2"]
    enlarge_in, num_bits = 4, 3
    state = [nxt(0), reset, 1]

    def read(count: int) -> int:
        bits, power, max_power = 0, 1, 1 << count
        while power != max_power:
            bit = state[0] & state[1]
            state[1] >>= 1
            if state[1] == 0:
                state[1] = reset
                state[0] = nxt(state[2])
                state[2] += 1
            bits |= (1 if bit > 0 else 0) * power
            power <<= 1
        return bits

    first = read(2)
    if first == 0:
        unit = chr(read(8))
    elif first == 1:
        unit = chr(read(16))
    else:
        return ""
    dictionary.append(unit)
    w = unit
    result = [unit]
    total = 1
    iterations, max_iterations = 0, length * 6 + 16
    while True:
        iterations += 1
        if iterations > max_iterations:
            raise Corrupted("loop")
        if state[2] > length:
            return ""
        code = read(num_bits)
        if code == 0:
            dictionary.append(chr(read(8)))
            code = len(dictionary) - 1
            enlarge_in -= 1
        elif code == 1:
            dictionary.append(chr(read(16)))
            code = len(dictionary) - 1
            enlarge_in -= 1
        elif code == 2:
            return "".join(result)
        if enlarge_in == 0:
            enlarge_in = 1 << num_bits
            num_bits += 1
        if code < len(dictionary):
            entry = dictionary[code]
        elif code == len(dictionary):
            entry = w + w[0]
        else:
            raise Corrupted("bad code")
        total += len(entry)
        if total > max_units:
            raise TooLarge("expands past the safe limit")
        result.append(entry)
        dictionary.append(w + entry[0])
        enlarge_in -= 1
        w = entry
        if enlarge_in == 0:
            enlarge_in = 1 << num_bits
            num_bits += 1


def decompress_from_base64(data: str, max_units: int = MAX_UNITS) -> str | None:
    try:
        return _text(decompress_units(data, max_units))
    except Corrupted:
        return None
