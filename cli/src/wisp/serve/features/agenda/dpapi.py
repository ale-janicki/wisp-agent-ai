from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Protocol


class Protector(Protocol):
    def protect(self, data: bytes) -> bytes: ...
    def unprotect(self, data: bytes) -> bytes: ...


class DpapiProtector:
    def __init__(self) -> None:
        if sys.platform != "win32":
            raise OSError("DPAPI exists only on Windows")

    def protect(self, data: bytes) -> bytes:
        return _crypt(data, protect=True)

    def unprotect(self, data: bytes) -> bytes:
        return _crypt(data, protect=False)


def _crypt(data: bytes, protect: bool) -> bytes:
    import ctypes
    from ctypes import wintypes

    class Blob(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    function = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    function.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    buffer = ctypes.create_string_buffer(data, len(data))
    source = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_char)))
    target = Blob()
    ok = function(ctypes.byref(source), None, None, None, None, 0, ctypes.byref(target))
    if not ok:
        raise OSError(ctypes.get_last_error(), "DPAPI failed")
    try:
        return ctypes.string_at(target.pbData, target.cbData)
    finally:
        kernel32.LocalFree(target.pbData)


def default_protector() -> Protector | None:
    return DpapiProtector() if sys.platform == "win32" else None


def local_dir(env=None) -> Path:
    env = os.environ if env is None else env
    base = Path(env["LOCALAPPDATA"]) if env.get("LOCALAPPDATA") else Path.home() / "AppData" / "Local"
    return base / "wisp"


class SecretFile:
    def __init__(self, name: str, protector: Protector | None, directory: Path | None = None) -> None:
        self.path = (directory or local_dir()) / name
        self.protector = protector

    @property
    def available(self) -> bool:
        return self.protector is not None

    def read(self) -> bytes | None:
        if self.protector is None:
            return None
        try:
            return self.protector.unprotect(self.path.read_bytes())
        except OSError:
            return None

    def write(self, data: bytes) -> None:
        if self.protector is None:
            raise OSError("sem DPAPI neste sistema")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(self.path.name + ".tmp")
        temporary.write_bytes(self.protector.protect(data))
        os.replace(temporary, self.path)

    def delete(self) -> None:
        self.path.unlink(missing_ok=True)
