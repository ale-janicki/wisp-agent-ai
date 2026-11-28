from __future__ import annotations

import ctypes
import sys
import time
from ctypes import wintypes

from .service import ClipboardBusy

CF_UNICODETEXT = 13
CF_DIB = 8
CF_DIBV5 = 17
GMEM_MOVEABLE = 0x0002
OPEN_RETRIES = 10
OPEN_PAUSE = 0.02


class WindowsClipboard:
    def __init__(self) -> None:
        if sys.platform != "win32":
            raise OSError("the Windows clipboard exists only on Windows")
        self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        u, k = self.user32, self.kernel32
        u.GetClipboardSequenceNumber.restype = wintypes.DWORD
        u.OpenClipboard.argtypes = [wintypes.HWND]
        u.OpenClipboard.restype = wintypes.BOOL
        u.CloseClipboard.restype = wintypes.BOOL
        u.EmptyClipboard.restype = wintypes.BOOL
        u.EnumClipboardFormats.argtypes = [wintypes.UINT]
        u.EnumClipboardFormats.restype = wintypes.UINT
        u.GetClipboardFormatNameW.argtypes = [wintypes.UINT, wintypes.LPWSTR, ctypes.c_int]
        u.GetClipboardFormatNameW.restype = ctypes.c_int
        u.GetClipboardData.argtypes = [wintypes.UINT]
        u.GetClipboardData.restype = ctypes.c_void_p
        u.SetClipboardData.argtypes = [wintypes.UINT, ctypes.c_void_p]
        u.SetClipboardData.restype = ctypes.c_void_p
        u.RegisterClipboardFormatW.argtypes = [wintypes.LPCWSTR]
        u.RegisterClipboardFormatW.restype = wintypes.UINT
        k.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
        k.GlobalAlloc.restype = ctypes.c_void_p
        k.GlobalLock.argtypes = [ctypes.c_void_p]
        k.GlobalLock.restype = ctypes.c_void_p
        k.GlobalUnlock.argtypes = [ctypes.c_void_p]
        k.GlobalSize.argtypes = [ctypes.c_void_p]
        k.GlobalSize.restype = ctypes.c_size_t
        k.GlobalFree.argtypes = [ctypes.c_void_p]
        self.png_format = u.RegisterClipboardFormatW("PNG")

    def sequence(self) -> int:
        return int(self.user32.GetClipboardSequenceNumber())

    def _open_or_busy(self) -> None:
        if not self._open():
            raise ClipboardBusy("a área de transferência está em uso")

    def read_flag(self, name: str) -> int | None:
        self._open_or_busy()
        try:
            data = self._read(self.user32.RegisterClipboardFormatW(name))
        finally:
            self.user32.CloseClipboard()
        return int.from_bytes(data[:4], "little") if data and len(data) >= 4 else None

    def _open(self) -> bool:
        for _ in range(OPEN_RETRIES):
            if self.user32.OpenClipboard(None):
                return True
            time.sleep(OPEN_PAUSE)
        return False

    def formats(self) -> list[str]:
        self._open_or_busy()
        try:
            names, current = [], 0
            while True:
                current = self.user32.EnumClipboardFormats(current)
                if not current:
                    break
                buffer = ctypes.create_unicode_buffer(256)
                length = self.user32.GetClipboardFormatNameW(current, buffer, 256)
                names.append(buffer.value if length > 0 else str(current))
            return names
        finally:
            self.user32.CloseClipboard()

    def _read(self, fmt: int) -> bytes | None:
        handle = self.user32.GetClipboardData(fmt)
        if not handle:
            return None
        size = self.kernel32.GlobalSize(handle)
        pointer = self.kernel32.GlobalLock(handle)
        if not pointer:
            return None
        try:
            return ctypes.string_at(pointer, size)
        finally:
            self.kernel32.GlobalUnlock(handle)

    def read_text(self) -> str | None:
        self._open_or_busy()
        try:
            data = self._read(CF_UNICODETEXT)
        finally:
            self.user32.CloseClipboard()
        return None if data is None else data.decode("utf-16-le", "replace").split("\x00", 1)[0]

    def read_image(self) -> bytes | None:
        self._open_or_busy()
        try:
            return self._read(self.png_format) or self._read(CF_DIB)
        finally:
            self.user32.CloseClipboard()

    def _write(self, writes: list[tuple[int, bytes]]) -> None:
        if not self._open():
            raise OSError("a área de transferência está em uso")
        try:
            self.user32.EmptyClipboard()
            for fmt, data in writes:
                handle = self.kernel32.GlobalAlloc(GMEM_MOVEABLE, len(data))
                pointer = self.kernel32.GlobalLock(handle)
                ctypes.memmove(pointer, data, len(data))
                self.kernel32.GlobalUnlock(handle)
                if not self.user32.SetClipboardData(fmt, handle):
                    self.kernel32.GlobalFree(handle)
        finally:
            self.user32.CloseClipboard()

    def write_text(self, text: str) -> None:
        self._write([(CF_UNICODETEXT, text.encode("utf-16-le") + b"\x00\x00")])

    def write_image(self, png: bytes) -> None:
        self._write([(self.png_format, png)])
