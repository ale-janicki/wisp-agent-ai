from __future__ import annotations

import struct
import zlib

THUMBNAIL_PIXELS = 160
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def encode_png(width: int, height: int, rows: list[bytes]) -> bytes:
    raw = b"".join(b"\x00" + row for row in rows)
    return (PNG_SIGNATURE + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(raw, 6)) + _chunk(b"IEND", b""))


def decode_dib(data: bytes) -> tuple[int, int, list[bytes]] | None:
    if len(data) < 40:
        return None
    size, width, height, planes, bits, compression = struct.unpack_from("<IiiHHI", data, 0)
    if size < 40 or planes != 1 or bits not in (24, 32) or compression not in (0, 3) or width <= 0 or height == 0:
        return None
    top_down = height < 0
    height = abs(height)
    if width * height > 100_000_000:
        return None
    offset = size + (12 if compression == 3 and size == 40 else 0)
    pixel = bits // 8
    stride = (width * bits + 31) // 32 * 4
    if len(data) < offset + stride * height:
        return None
    rows = []
    for y in range(height):
        start = offset + stride * (y if top_down else height - 1 - y)
        line = data[start:start + width * pixel]
        out = bytearray(width * 3)
        out[0::3], out[1::3], out[2::3] = line[2::pixel], line[1::pixel], line[0::pixel]
        rows.append(bytes(out))
    return width, height, rows


def thumbnail_rows(width: int, height: int, rows: list[bytes], limit: int = THUMBNAIL_PIXELS) -> tuple[int, int, list[bytes]]:
    scale = min(1.0, limit / max(width, height))
    new_w, new_h = max(1, int(width * scale)), max(1, int(height * scale))
    columns = [min(width - 1, int(x / scale)) for x in range(new_w)]
    out = []
    for y in range(new_h):
        row = rows[min(height - 1, int(y / scale))]
        out.append(b"".join(row[c * 3:c * 3 + 3] for c in columns))
    return new_w, new_h, out


def encode(raw: bytes) -> tuple[bytes, bytes] | None:
    if raw.startswith(PNG_SIGNATURE):
        return raw, raw
    decoded = decode_dib(raw)
    if decoded is None:
        return None
    width, height, rows = decoded
    t_w, t_h, t_rows = thumbnail_rows(width, height, rows)
    return encode_png(width, height, rows), encode_png(t_w, t_h, t_rows)
