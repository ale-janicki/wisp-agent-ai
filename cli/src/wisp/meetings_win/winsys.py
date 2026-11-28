from __future__ import annotations

import base64
import binascii
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Callable

from wisp.meetings_win.transcript import write_private


class NotWindows(RuntimeError):
    def __init__(self):
        super().__init__("só funciona no Windows")


def _require() -> None:
    if sys.platform != "win32":
        raise NotWindows()


def trash(path: Path) -> None:
    _require()
    import ctypes
    from ctypes import wintypes

    class SHFILEOPSTRUCTW(ctypes.Structure):
        _pack_ = 1 if ctypes.sizeof(ctypes.c_void_p) == 4 else 8
        _fields_ = [("hwnd", wintypes.HWND), ("wFunc", wintypes.UINT), ("pFrom", wintypes.LPCWSTR),
                    ("pTo", wintypes.LPCWSTR), ("fFlags", ctypes.c_ushort), ("fAnyOperationsAborted", wintypes.BOOL),
                    ("hNameMappings", ctypes.c_void_p), ("lpszProgressTitle", wintypes.LPCWSTR)]

    FO_DELETE, FOF_SILENT, FOF_NOCONFIRMATION, FOF_ALLOWUNDO, FOF_NOERRORUI = 3, 0x4, 0x10, 0x40, 0x400
    operation = SHFILEOPSTRUCTW()
    operation.wFunc = FO_DELETE
    operation.pFrom = str(Path(path).resolve()) + "\0"
    operation.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI
    code = ctypes.windll.shell32.SHFileOperationW(ctypes.byref(operation))
    if code != 0 or operation.fAnyOperationsAborted:
        raise OSError(f"o Windows não moveu para a lixeira (código {code})")


def reveal(path: Path) -> None:
    _require()
    target = Path(path)
    if target.is_dir():
        os.startfile(str(target))  # noqa: S606
    else:
        subprocess.Popen(["explorer", f"/select,{target}"])


def open_path(path: Path) -> None:
    _require()
    os.startfile(str(path))  # noqa: S606


def _blob(data: bytes):
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    buffer = ctypes.create_string_buffer(data, len(data))
    return DATA_BLOB(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_char))), buffer, DATA_BLOB


def _crypt(data: bytes, protect: bool) -> bytes:
    _require()
    import ctypes

    source, keep, blob_type = _blob(data)
    out = blob_type()
    call = ctypes.windll.crypt32.CryptProtectData if protect else ctypes.windll.crypt32.CryptUnprotectData
    ok = call(ctypes.byref(source), None, None, None, None, 0, ctypes.byref(out))
    if not ok:
        raise OSError("o Windows não conseguiu proteger ou ler o segredo")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(out.pbData)
        del keep


def dpapi_protect(data: bytes) -> bytes:
    return _crypt(data, True)


def dpapi_unprotect(data: bytes) -> bytes:
    return _crypt(data, False)


class CredentialStore:
    def __init__(self, path: Path, protect: Callable[[bytes], bytes] | None = None,
                 unprotect: Callable[[bytes], bytes] | None = None):
        self._path = Path(path)
        self._protect = protect or dpapi_protect
        self._unprotect = unprotect or dpapi_unprotect

    def _load(self) -> dict:
        try:
            data = json.loads(self._path.read_text("utf-8"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def get(self, name: str) -> str | None:
        raw = self._load().get(name)
        if not isinstance(raw, str):
            return None
        try:
            return self._unprotect(base64.b64decode(raw, validate=True)).decode("utf-8")
        except (binascii.Error, ValueError, OSError):
            return None

    def set(self, name: str, value: str) -> None:
        data = self._load()
        data[name] = base64.b64encode(self._protect(value.encode("utf-8"))).decode("ascii")
        self._save(data)

    def delete(self, name: str) -> None:
        data = self._load()
        if data.pop(name, None) is not None:
            self._save(data)

    def _save(self, data: dict) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        write_private(self._path, json.dumps(data, indent=2, sort_keys=True))
