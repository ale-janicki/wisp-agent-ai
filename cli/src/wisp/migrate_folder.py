import errno
import fcntl
import json
import os
import shutil
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from wisp.arquivos import _mover_sem_sobrescrever
from wisp.config import WispConfig, save_config
from wisp.fsops import atomic_write, ensure_dir
from wisp.layout import DEFAULT_WISP_DIR, FolderLayout, expand, layout_of
from wisp.paths import WispPaths
from wisp.report import StepReport

NOTE = "MOVIDO.txt"
LOG = "migracao.log"
PART = ".wisp-part-"
STEP = "folder-migrate"
ENTRY_CAP = 256 * 1024 * 1024
TOTAL_CAP = 1024 * 1024 * 1024

UNSUPPORTED = (errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENOSYS)
NO_HARD_LINKS = (*UNSUPPORTED, errno.EPERM)
NOTES_SKIPPED = {".git", ".obsidian"}
RECENT_SECONDS = 60

Progress = Callable[[int, int, str], None]


@dataclass
class Moves:
    moved: list[tuple[Path, Path]] = field(default_factory=list)
    conflicts: list[tuple[Path, Path]] = field(default_factory=list)
    failed: list[tuple[Path, str]] = field(default_factory=list)
    left: list[tuple[Path, str]] = field(default_factory=list)
    skipped: list[tuple[Path, Path]] = field(default_factory=list)


def _attachment_sources(cfg: WispConfig, paths: WispPaths, layout: FolderLayout) -> list[tuple[Path, Path]]:
    state = expand(cfg.telegram.state_dir, paths.home) if cfg.telegram else paths.state / "bot"
    return [
        (paths.home / "Library/Application Support/Wisp/anexos", layout.anexos),
        (state / "anexos", layout.anexos),
    ]


def _legacy_meetings(paths: WispPaths) -> Path:
    return paths.home / DEFAULT_WISP_DIR[2:] / "reunioes"


def _identical(a: Path, b: Path) -> bool:
    try:
        return os.path.samefile(a, b)
    except OSError:
        return a.resolve() == b.resolve()


def _inside(child: Path, parent: Path) -> bool:
    resolved = child.resolve()
    return any(_identical(p, parent) for p in (resolved, *resolved.parents))


def _same(a: Path, b: Path) -> bool:
    return _identical(a, b)


def _nested(a: Path, b: Path) -> bool:
    return _inside(a, b) or _inside(b, a)


def _newest_mtime(path: Path) -> float:
    try:
        newest = path.lstat().st_mtime
    except OSError:
        return 0.0
    if path.is_dir() and not path.is_symlink():
        for folder, dirs, names in os.walk(path):
            for name in (*dirs, *names):
                try:
                    newest = max(newest, os.lstat(os.path.join(folder, name)).st_mtime)
                except OSError:
                    pass
    return newest


def _is_recent(path: Path) -> bool:
    return time.time() - _newest_mtime(path) < RECENT_SECONDS


def _recording_active(entry: Path) -> bool:
    try:
        status = json.loads((entry / "meta.json").read_text("utf-8")).get("status")
    except (OSError, ValueError, AttributeError):
        return False
    return status == "recording" and _is_recent(entry)


def _relink(link: Path, original: Path, translate: Callable[[Path], Path]) -> None:
    target = os.readlink(link)
    if os.path.isabs(target):
        return
    wanted = translate(Path(os.path.normpath(original.parent / target)))
    fixed = os.path.relpath(wanted, link.parent)
    if fixed == target:
        return
    temp = link.with_name(PART + link.name)
    temp.unlink(missing_ok=True)
    os.symlink(fixed, temp)
    os.replace(temp, link)


def _fix_links(src: Path, dst: Path, old: Path, new: Path) -> None:
    def translate(path: Path) -> Path:
        for base, moved in ((src, dst), (old, new)):
            try:
                return moved / path.relative_to(base)
            except ValueError:
                continue
        return path

    if dst.is_symlink():
        _relink(dst, src, translate)
        return
    for folder, dirs, names in os.walk(dst):
        for name in (*dirs, *names):
            path = Path(folder) / name
            if path.is_symlink():
                _relink(path, src / path.relative_to(dst), translate)


def _exclusive_file(src: Path, dst: Path) -> None:
    if src.is_symlink():
        os.symlink(os.readlink(src), dst)
        src.unlink()
        return
    try:
        os.link(src, dst)
    except OSError as e:
        if e.errno not in NO_HARD_LINKS:
            raise
    else:
        src.unlink()
        return
    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as out, open(src, "rb") as source:
            shutil.copyfileobj(source, out)
            out.flush()
            _flush(out.fileno())
        shutil.copystat(src, dst)
    except BaseException:
        dst.unlink(missing_ok=True)
        raise
    src.unlink()


def _exclusive_dir(src: Path, dst: Path) -> None:
    os.mkdir(dst)
    for child in sorted(src.iterdir()):
        _exclusive(child, dst / child.name)
    os.rmdir(src)


def _exclusive(src: Path, dst: Path) -> None:
    is_dir = src.is_dir() and not src.is_symlink()
    try:
        if is_dir and sys.platform != "darwin":
            os.mkdir(dst)
            try:
                os.rename(src, dst)
            except OSError:
                os.rmdir(dst)
                raise
        else:
            _mover_sem_sobrescrever(src, dst)
    except OSError as e:
        if e.errno not in UNSUPPORTED:
            raise
        _exclusive_dir(src, dst) if is_dir else _exclusive_file(src, dst)


def _flush(fd: int) -> None:
    if sys.platform == "darwin":
        try:
            fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
            return
        except OSError:
            pass
    os.fsync(fd)


def _fsync_path(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        _flush(fd)
    finally:
        os.close(fd)


def _copy_file_synced(src, dst, *, follow_symlinks=True):
    shutil.copy2(src, dst, follow_symlinks=follow_symlinks)
    if not os.path.islink(dst):
        _fsync_path(Path(dst))
    return dst


def _copy_synced(src: Path, staged: Path) -> None:
    if src.is_dir() and not src.is_symlink():
        shutil.copytree(src, staged, symlinks=True, copy_function=_copy_file_synced)
        for folder, _, _ in os.walk(staged):
            _fsync_path(Path(folder))
    else:
        _copy_file_synced(src, staged, follow_symlinks=False)
    _fsync_path(staged.parent)


def _remove(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif os.path.lexists(path):
        path.unlink()


def _remove_source(src: Path) -> list[str]:
    errors: list[str] = []
    if src.is_dir() and not src.is_symlink():
        shutil.rmtree(src, onexc=lambda _f, path, exc: errors.append(f"{path}: {exc}"))
    else:
        try:
            src.unlink()
        except OSError as e:
            errors.append(f"{src}: {e}")
    return errors


def _place(src: Path, dst: Path, budget: list[int] | None = None) -> tuple[str, list[str]]:
    ensure_dir(dst.parent)
    try:
        _exclusive(src, dst)
        return "moved", []
    except FileExistsError:
        return "conflict", []
    except OSError as e:
        if e.errno != errno.EXDEV:
            raise
    if budget is not None:
        size = _size(src)
        if size > ENTRY_CAP:
            return "left", ["grande demais para mover ao abrir o app"]
        if budget[0] + size > TOTAL_CAP:
            return "left", ["fica para a próxima vez"]
        budget[0] += size
    staged = dst.with_name(PART + dst.name)
    _remove(staged)
    _copy_synced(src, staged)
    try:
        _exclusive(staged, dst)
    except FileExistsError:
        _remove(staged)
        return "conflict", []
    _fsync_path(dst.parent)
    errors = _remove_source(src)
    return ("partial", errors) if errors else ("moved", [])


def _size(path: Path) -> int:
    if path.is_symlink() or not path.is_dir():
        try:
            return path.lstat().st_size
        except OSError:
            return 0
    total = 0
    for folder, _, names in os.walk(path):
        for name in names:
            try:
                total += os.lstat(os.path.join(folder, name)).st_size
            except OSError:
                pass
    return total


def _entries(old: Path) -> list[Path]:
    try:
        return sorted(p for p in old.iterdir() if p.name != NOTE and not p.name.startswith(PART))
    except OSError:
        return []


def _clear_stale(folder: Path) -> None:
    if folder.is_dir():
        for part in folder.glob(PART + "*"):
            _remove(part)


class _Log:
    def __init__(self, path: Path):
        self.path = path
        try:
            self.known = {line.split("\t", 1)[1] for line in path.read_text("utf-8").splitlines() if "\t" in line}
        except OSError:
            self.known = set()

    def write(self, kind: str, detail: str, *, once: bool = False) -> None:
        row = f"{kind}\t{detail}"
        if once and row in self.known:
            return
        ensure_dir(self.path.parent)
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(f"{stamp}\t{row}\n")
            f.flush()
            os.fsync(f.fileno())
        self.known.add(row)


def _write_note(old: Path, new: Path, log: Path, moved: list[Path]) -> None:
    note = old / NOTE
    names: list[str] = []
    try:
        names = [line for line in note.read_text("utf-8").splitlines() if line.startswith("- ")]
    except OSError:
        pass
    for path in moved:
        line = f"- {path.name}"
        if line not in names:
            names.append(line)
    body = f"Estes itens foram movidos para {new} (registro em {log}):\n" + "\n".join(names) + "\n"
    atomic_write(note, body)


def _retarget_profile(profile: Path, old: list[Path], new: Path, home: Path) -> bool:
    if profile.is_symlink() or not profile.is_file():
        return False
    try:
        data = json.loads(profile.read_text("utf-8"))
        block = data["blocks"]["telegram"]
        current = block["attachments"]
    except (OSError, ValueError, KeyError, TypeError):
        return False
    if not isinstance(current, str) or not any(_same(expand(current, home), path) for path in old):
        return False
    block["attachments"] = str(new)
    atomic_write(profile, json.dumps(data, indent=2, ensure_ascii=False) + "\n", mode=0o600)
    return True


def _has_notes(folder: Path) -> bool:
    for _, dirs, names in os.walk(folder):
        dirs[:] = [d for d in dirs if d not in NOTES_SKIPPED]
        if any(name.lower().endswith(".md") for name in names):
            return True
    return False


def _pin_legacy_brain(cfg: WispConfig, paths: WispPaths, layout: FolderLayout) -> bool:
    legacy = paths.home / DEFAULT_WISP_DIR[2:] / "brain"
    if cfg.brain or _same(legacy, layout.brain) or not legacy.is_dir() or not _has_notes(legacy):
        return False
    cfg.brain = str(legacy)
    save_config(cfg)
    return True


def _run_pairs(
    pairs: list[tuple[Path, Path]], log: _Log, moves: Moves, *, capped: bool, progress: Progress | None,
    skip_recent: bool = False,
) -> list[tuple[Path, Path, list[Path]]]:
    touched: list[tuple[Path, Path, list[Path]]] = []
    budget: list[int] | None = [0] if capped else None
    work: list[tuple[Path, Path, list[Path]]] = []
    for old, new in pairs:
        if _same(old, new):
            continue
        if old.is_symlink():
            moves.skipped.append((old, new))
            log.write("pulou", f"{old} -> {new}: a pasta antiga é um atalho", once=True)
            continue
        if _nested(old, new):
            moves.skipped.append((old, new))
            log.write("pulou", f"{old} -> {new}: uma pasta está dentro da outra", once=True)
            continue
        entries = _entries(old)
        if entries:
            work.append((old, new, entries))
    total = sum(len(entries) for _, _, entries in work)
    done = 0
    for old, new, entries in work:
        try:
            _clear_stale(new)
        except OSError as e:
            reason = e.strerror or type(e).__name__
            done += len(entries)
            moves.failed.append((new, reason))
            log.write("falhou", f"{new}: {reason}")
            continue
        moved_here: list[Path] = []
        for entry in entries:
            done += 1
            target = new / entry.name
            if skip_recent and _is_recent(entry):
                moves.left.append((entry, "modificada há pouco"))
                log.write("ficou", f"{entry}: modificada há pouco", once=True)
                if progress:
                    progress(done, total, entry.name)
                continue
            try:
                status, errors = _place(entry, target, budget)
            except OSError as e:
                moves.failed.append((entry, e.strerror or type(e).__name__))
                log.write("falhou", f"{entry}: {e.strerror or type(e).__name__}")
            else:
                if status == "conflict":
                    moves.conflicts.append((entry, target))
                    log.write("conflito", f"{entry} -> {target}", once=True)
                elif status == "left":
                    moves.left.append((entry, errors[0]))
                    log.write("ficou", f"{entry}: {errors[0]}", once=True)
                else:
                    moves.moved.append((entry, target))
                    moved_here.append(entry)
                    log.write("moveu", f"{entry} -> {target}")
                    try:
                        _fix_links(entry, target, old, new)
                    except OSError as e:
                        reason = e.strerror or type(e).__name__
                        moves.failed.append((target, f"atalho não corrigido: {reason}"))
                        log.write("falhou", f"{target}: atalho não corrigido: {reason}")
                    if errors:
                        moves.failed.append((entry, "copiado, mas não consegui apagar a origem: " + "; ".join(errors)))
                        log.write("parcial", f"{entry}: {'; '.join(errors)}")
            if progress:
                progress(done, total, entry.name)
        if moved_here:
            _write_note(old, new, log.path, moved_here)
            touched.append((old, new, moved_here))
    return touched


def _report(moves: Moves, log: Path, extra: dict[str, str]) -> StepReport:
    data = {
        "moved": str(len(moves.moved)), "conflicts": str(len(moves.conflicts)), "failed": str(len(moves.failed)),
        "left": str(len(moves.left)), "skipped": str(len(moves.skipped)), "log": str(log), **extra,
    }
    if not (moves.moved or moves.conflicts or moves.failed or moves.left or moves.skipped or extra):
        return StepReport(STEP, "skipped", "nada para mover", data=data)
    if moves.failed:
        return StepReport(STEP, "failed", "não consegui mover alguns itens; o resto ficou no lugar de antes", data=data)
    parts = [f"{len(moves.moved)} itens movidos"]
    if moves.conflicts:
        parts.append(f"{len(moves.conflicts)} já existiam no destino e ficaram nos dois lugares")
    if moves.left:
        parts.append(f"{len(moves.left)} ficaram onde estavam")
    if moves.skipped:
        parts.append(f"{len(moves.skipped)} pastas puladas por uma estar dentro da outra")
    return StepReport(STEP, "done", "; ".join(parts), data=data)


def migrate_folder(paths: WispPaths, cfg: WispConfig) -> StepReport:
    layout = layout_of(cfg, paths.home)
    extra: dict[str, str] = {}
    if _pin_legacy_brain(cfg, paths, layout):
        extra["brain"] = "mantido em " + cfg.brain
        layout = layout_of(cfg, paths.home)
    moves = Moves()
    log = _Log(layout.logs / LOG)
    pairs = _attachment_sources(cfg, paths, layout)
    _run_pairs(pairs, log, moves, capped=True, progress=None)
    old_anexos = [old for old, _ in pairs]
    if _retarget_profile(paths.config / "profile.json", old_anexos, layout.anexos, paths.home):
        extra["profile"] = "attachments"
    return _report(moves, log.path, extra)


def meetings_pending(paths: WispPaths, cfg: WispConfig) -> int:
    layout = layout_of(cfg, paths.home)
    old = _legacy_meetings(paths)
    if _same(old, layout.reunioes) or _nested(old, layout.reunioes):
        return 0
    return len(_entries(old))


def migrate_meetings(paths: WispPaths, cfg: WispConfig, progress: Progress | None = None) -> StepReport:
    layout = layout_of(cfg, paths.home)
    moves = Moves()
    log = _Log(layout.logs / LOG)
    old = _legacy_meetings(paths)
    if any(_recording_active(entry) for entry in _entries(old)):
        return StepReport(
            STEP, "failed", "há uma reunião sendo gravada; espere terminar e tente de novo", data={"recording": "true"}
        )
    _run_pairs([(old, layout.reunioes)], log, moves, capped=False, progress=progress, skip_recent=True)
    return _report(moves, log.path, {})
