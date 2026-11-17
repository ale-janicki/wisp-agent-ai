import os
import shutil
import tempfile
from pathlib import Path


class OutsideHome(Exception):
    pass


def _check_inside_home(path: Path) -> Path:
    resolved = path.resolve()
    if not resolved.is_relative_to(Path.home().resolve()):
        raise OutsideHome(f"refusing to write outside the home folder: {path}")
    return resolved


def atomic_write(path: Path, data: bytes | str, mode: int = 0o644) -> None:
    target = _check_inside_home(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = data.encode() if isinstance(data, str) else data
    fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(payload)
        os.chmod(tmp, mode)
        os.replace(tmp, target)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def copy_file(src: Path, dst: Path) -> None:
    atomic_write(dst, src.read_bytes(), mode=src.stat().st_mode & 0o777)


def ensure_dir(path: Path, mode: int = 0o755) -> None:
    _check_inside_home(path).mkdir(parents=True, exist_ok=True, mode=mode)
