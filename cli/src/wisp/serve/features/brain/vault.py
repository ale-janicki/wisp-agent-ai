from __future__ import annotations

import os
import shutil
import stat
import sys
import tempfile
import time
import uuid
import re
from collections.abc import Callable
from pathlib import Path

HIDDEN_PREFIX = "."
TMP_PREFIX = ".wisp-tmp-"
DRIVE = re.compile(r"^[A-Za-z]:[\\/]")
RESERVED = frozenset({"CON", "PRN", "AUX", "NUL", *(f"COM{n}" for n in range(1, 10)), *(f"LPT{n}" for n in range(1, 10))})
REPLACE_TRIES = 3
REPLACE_PAUSE = 0.1


class VaultError(Exception):
    pass


class Outside(VaultError):
    pass


class InvalidName(VaultError):
    pass


class Exists(VaultError):
    pass


class Missing(VaultError):
    pass


class ReadOnly(VaultError):
    pass


class Busy(VaultError):
    pass


def check_name(rel: str) -> None:
    for part in rel.split("/"):
        if any(c in part for c in (":", "\\", "\0")):
            raise InvalidName(f"nome inválido: {rel}")
        if part.endswith((".", " ")) or part.split(".")[0].rstrip(" ").upper() in RESERVED:
            raise InvalidName(f"nome inválido no Windows: {rel}")


def strict_text(data: bytes) -> str | None:
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def _recycle_windows(path: Path) -> None:
    import ctypes
    from ctypes import wintypes

    class FileOp(ctypes.Structure):
        _fields_ = [
            ("hwnd", wintypes.HWND), ("wFunc", wintypes.UINT), ("pFrom", wintypes.LPCWSTR), ("pTo", wintypes.LPCWSTR),
            ("fFlags", ctypes.c_ushort), ("fAnyOperationsAborted", wintypes.BOOL), ("hNameMappings", ctypes.c_void_p),
            ("lpszProgressTitle", wintypes.LPCWSTR),
        ]

    delete, allow_undo, no_confirm, silent, no_error_ui = 3, 0x40, 0x10, 0x4, 0x400
    op = FileOp(None, delete, str(path) + "\0", None, allow_undo | no_confirm | silent | no_error_ui, False, None, None)
    code = ctypes.windll.shell32.SHFileOperationW(ctypes.byref(op))  # type: ignore[attr-defined]
    if code != 0 or op.fAnyOperationsAborted:
        raise VaultError(f"não consegui mandar {path.name} para a Lixeira (código {code})")


def _recycle(path: Path, root: Path) -> None:
    if sys.platform == "win32":
        _recycle_windows(path)
        return
    folder = root / ".trash"
    folder.mkdir(exist_ok=True)
    shutil.move(str(path), str(folder / f"{path.name}.{uuid.uuid4().hex[:6]}"))


class Vault:
    def __init__(self, root: Path | str, trasher: Callable[[Path], None] | None = None):
        self.root = Path(root).expanduser().resolve()
        self._trasher = trasher or (lambda path: _recycle(path, self.root))

    def _inside(self, path: Path) -> bool:
        return path == self.root or path.is_relative_to(self.root)

    def path(self, rel: str, write: bool = False) -> Path:
        if write:
            check_name(rel)
        if not rel or rel.startswith(("/", "\\")) or DRIVE.match(rel):
            raise Outside(f"{rel} está fora do brain")
        for part in rel.split("/"):
            if not part or part.startswith(HIDDEN_PREFIX) or "\\" in part or "\0" in part:
                raise Outside(f"{rel} está fora do brain")
        target = self.root / rel
        probe = target.parent
        while not probe.exists() and probe != self.root:
            probe = probe.parent
        if not self._inside(probe.resolve()):
            raise Outside(f"{rel} está fora do brain")
        return target

    def validate_new(self, rel: str) -> Path:
        check_name(rel)
        return self.path(rel)

    def root_contains(self, path: str | Path) -> bool:
        return self._inside(Path(path))

    def exists(self, rel: str) -> bool:
        try:
            return os.path.lexists(self.path(rel))
        except VaultError:
            return False

    def tree(self) -> list[dict]:
        entries: list[dict] = []
        for current, dirs, names in os.walk(self.root):
            dirs[:] = sorted(d for d in dirs if not d.startswith(HIDDEN_PREFIX))
            base = Path(current)
            for name in dirs:
                rel = (base / name).relative_to(self.root).as_posix()
                try:
                    entries.append({"path": rel, "is_folder": True, "modified": (base / name).stat().st_mtime, "size": 0})
                except OSError:
                    continue
            for name in sorted(names):
                if name.startswith(HIDDEN_PREFIX):
                    continue
                full = base / name
                try:
                    info = full.stat()
                except OSError:
                    continue
                if not stat.S_ISREG(info.st_mode):
                    continue
                entries.append({"path": full.relative_to(self.root).as_posix(), "is_folder": False,
                                "modified": info.st_mtime, "size": info.st_size, "symlink": full.is_symlink()})
        return entries

    def _real_inside(self, rel: str) -> Path:
        path = self.path(rel)
        if not self._inside(Path(os.path.realpath(path))):
            raise Outside(f"{rel} aponta para fora do brain")
        return path

    def size(self, rel: str) -> int:
        try:
            return self._real_inside(rel).stat().st_size
        except OSError as error:
            raise Missing(f"não achei {rel}") from error

    def read_bytes(self, rel: str) -> bytes:
        path = self._real_inside(rel)
        try:
            return path.read_bytes()
        except OSError as error:
            raise Missing(f"não achei {rel}") from error

    def read_strict(self, rel: str) -> str:
        text = strict_text(self.read_bytes(rel))
        if text is None:
            raise ReadOnly(f"{rel} não é texto UTF-8 válido")
        return text

    def _target(self, rel: str) -> Path:
        path = self.path(rel)
        real = Path(os.path.realpath(path))
        if not self._inside(real):
            raise ReadOnly(f"{rel} é um link simbólico para fora do brain; aberta só para leitura")
        return real

    def write_problem(self, rel: str) -> str | None:
        try:
            path = self.path(rel)
        except VaultError:
            return f"{rel} está fora do brain; aberta só para leitura"
        if not path.exists():
            return None
        try:
            target = self._target(rel)
        except ReadOnly as error:
            return str(error)
        if target.stat().st_nlink > 1:
            return f"{rel} tem mais de um link físico; aberta só para leitura para não separar as cópias"
        try:
            readable = strict_text(target.read_bytes()) is not None
        except OSError:
            readable = False
        if not readable:
            return f"{rel} não é texto UTF-8 válido (ou tem bytes nulos); aberta só para leitura e nunca será gravada"
        return None

    def inspect(self, rel: str) -> tuple[str, str | None]:
        raw = self.read_bytes(rel)
        return raw.decode("utf-8", errors="replace"), self.write_problem(rel)

    def write(self, rel: str, text: str) -> None:
        check_name(rel)
        problem = self.write_problem(rel)
        if problem:
            raise ReadOnly(problem)
        path = self.path(rel, write=True)
        destination = self._target(rel) if path.exists() else path
        self.write_bytes_atomic(destination, text.encode("utf-8"))

    @staticmethod
    def replace(source: str | Path, destination: Path) -> None:
        for attempt in range(REPLACE_TRIES):
            try:
                os.replace(source, destination)
                return
            except PermissionError as error:
                if attempt == REPLACE_TRIES - 1:
                    raise Busy(f"{destination.name} está em uso por outro programa; tente de novo") from error
                time.sleep(REPLACE_PAUSE)

    @staticmethod
    def write_bytes_atomic(destination: Path, data: bytes, like: Path | None = None) -> None:
        if destination.exists() and not os.access(destination, os.W_OK):
            raise ReadOnly(f"{destination.name} é somente leitura; tire o atributo e tente de novo")
        destination.parent.mkdir(parents=True, exist_ok=True)
        fd, temp = tempfile.mkstemp(dir=destination.parent, prefix=TMP_PREFIX)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            source = like or destination
            if sys.platform != "win32" and source.exists():
                shutil.copymode(source, temp)
            Vault.replace(temp, destination)
        except BaseException:
            Path(temp).unlink(missing_ok=True)
            raise

    def create(self, rel: str, text: str = "") -> None:
        path = self.validate_new(rel)
        if os.path.lexists(path):
            raise Exists(f"já existe {rel}")
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            with open(path, "xb") as handle:
                handle.write(text.encode("utf-8"))
        except FileExistsError as error:
            raise Exists(f"já existe {rel}") from error

    def mkdir(self, rel: str) -> None:
        path = self.validate_new(rel)
        if os.path.lexists(path):
            raise Exists(f"já existe {rel}")
        path.mkdir(parents=True)

    def is_case_only(self, src: str, dst: str) -> bool:
        if src == dst or src.lower() != dst.lower():
            return False
        try:
            a, b = os.lstat(self.path(src)), os.lstat(self.path(dst))
        except OSError:
            return False
        return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)

    def move(self, src: str, dst: str) -> None:
        source, target = self.path(src), self.validate_new(dst)
        if not os.path.lexists(source):
            raise Missing(f"não achei {src}")
        if os.path.lexists(target) and not self.is_case_only(src, dst):
            raise Exists(f"já existe {dst}")
        target.parent.mkdir(parents=True, exist_ok=True)
        os.rename(source, target)

    def trash(self, rel: str) -> None:
        path = self.path(rel)
        if not os.path.lexists(path):
            raise Missing(f"não achei {rel}")
        self._trasher(path)

    def is_hard_linked(self, rel: str) -> bool:
        try:
            return self.path(rel).stat().st_nlink > 1
        except OSError:
            return False
