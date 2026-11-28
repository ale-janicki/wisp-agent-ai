from __future__ import annotations

import posixpath
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from wisp.brain_index import READ_CAP, Graph

from . import links
from .catalog import Catalog
from .vault import TMP_PREFIX, Exists, Missing, Outside, Vault, VaultError, strict_text


class Stale(VaultError):
    pass


@dataclass(frozen=True)
class Edit:
    old_path: str
    new_path: str
    old_text: str
    new_text: str
    count: int


@dataclass(frozen=True)
class MovePlan:
    source: str
    target: str
    is_folder: bool
    edits: tuple[Edit, ...]
    skipped: tuple[str, ...] = ()
    drawings: tuple[str, ...] = ()

    @property
    def is_complete(self) -> bool:
        return not self.skipped

    @property
    def link_count(self) -> int:
        return sum(e.count for e in self.edits)

    def to_dict(self) -> dict:
        return {"from": self.source, "to": self.target, "is_folder": self.is_folder, "is_complete": self.is_complete,
                "link_count": self.link_count, "file_count": len(self.edits), "skipped": list(self.skipped),
                "drawings": list(self.drawings), "edits": [{"path": e.old_path, "count": e.count} for e in self.edits]}


class FileResolver:
    def __init__(self, paths: list[str]):
        self.paths = paths
        self.lowered = {p.lower(): p for p in paths}

    def resolve(self, name: str, source: str | None) -> str | None:
        key = name.strip().removeprefix("./").lstrip("/").lower()
        if not key:
            return None
        if key in self.lowered:
            return self.lowered[key]
        found = [p for p in self.paths if p.lower().endswith("/" + key)]
        if not found and source and "/" in key:
            joined = posixpath.normpath(posixpath.join(posixpath.dirname(source), key))
            if joined in self.paths:
                return joined
        home = posixpath.dirname(source) if source else None
        return min(found, key=lambda p: (posixpath.dirname(p) != home, p.count("/"), p)) if found else None


def is_drawing(path: str) -> bool:
    lowered = path.lower()
    return lowered.endswith((".excalidraw.md", ".excalidraw", ".canvas"))


def relative_path(folder: str, path: str) -> str:
    base = [p for p in folder.split("/") if p]
    target = path.split("/")
    common = 0
    while common < len(base) and common < len(target) - 1 and base[common] == target[common]:
        common += 1
    return "/".join([".."] * (len(base) - common) + target[common:])


def _link_text(target: str, occ: links.Occurrence, source: str, graph: Graph, files: FileResolver) -> str:
    is_note = target in graph.notes and not occ.is_attachment
    keeps_suffix = occ.name.lower().endswith(".md")
    full = target[:-3] if is_note and not keeps_suffix and target.lower().endswith(".md") else target
    resolve = (lambda n: graph.resolve(n, source)) if is_note else (lambda n: files.resolve(n, source))
    if occ.name.startswith(("./", "../")):
        relative = relative_path(posixpath.dirname(source), full)
        return relative if resolve(relative) == target else full
    if "/" in occ.name:
        return full
    leaf = full.rsplit("/", 1)[-1]
    return leaf if resolve(leaf) == target else full


def plan(vault: Vault, catalog: Catalog, source: str, target: str) -> MovePlan:
    vault.path(source)
    vault.validate_new(target)
    entries = vault.tree()
    by_path = {e["path"]: e for e in entries}
    if source not in by_path:
        raise Missing(f"não achei {source}")
    if target == source or target.startswith(source + "/"):
        raise Outside(f"{target} está fora do brain")
    if vault.exists(target) and not vault.is_case_only(source, target):
        raise Exists(f"já existe {target}")

    def relocated(path: str) -> str:
        if path == source:
            return target
        return target + path[len(source) :] if path.startswith(source + "/") else path

    files = [e["path"] for e in entries if not e["is_folder"]]
    moved = {p: relocated(p) for p in files if p == source or p.startswith(source + "/")}
    old_files, new_files = FileResolver(files), FileResolver([relocated(p) for p in files])
    new_graph = catalog.moved(moved)

    candidates: set[str] = set()
    needles: set[str] = set()
    for path in moved:
        needles.add(PurePosixPath(path).name.lower())
        if not path.endswith(".md") or path not in catalog.notes:
            continue
        row = catalog.notes[path]
        candidates |= set(catalog.incoming(path)) | {path}
        needles |= {row.stem.lower(), row.title.lower(), *(a.lower() for a in row.aliases)}
    needles.discard("")
    drawings = {c for c in candidates if is_drawing(c)}
    candidates -= drawings
    moves_attachment = any(not p.endswith(".md") or p not in catalog.notes for p in moved)
    skipped: list[str] = []
    examined: dict[str, str] = {}
    for rel in catalog.notes:
        if rel in candidates or is_drawing(rel):
            continue
        if not (by_path.get(rel, {}).get("size", 0) > READ_CAP or moves_attachment):
            continue
        text = strict_text(_safe_bytes(vault, rel))
        if text is None:
            skipped.append(rel)
            continue
        lowered = text.lower()
        if any(n in lowered for n in needles):
            candidates.add(rel)
            examined[rel] = text

    edits: list[Edit] = []
    for path in sorted(candidates):
        if by_path.get(path, {}).get("symlink") or vault.is_hard_linked(path):
            skipped.append(path)
            continue
        text = examined.get(path) or strict_text(_safe_bytes(vault, path))
        if text is None:
            skipped.append(path)
            continue
        new_source = moved.get(path, path)
        changed, out = 0, text
        for occ in reversed(links.scan(text, include_frontmatter=True)):
            if not occ.name:
                continue
            attach = occ.is_attachment
            old_target = old_files.resolve(occ.name, path) if attach else catalog.resolve(occ.name, path)
            if old_target is None:
                continue
            new_target = moved.get(old_target, old_target)
            now = new_files.resolve(occ.name, new_source) if attach else new_graph.resolve(occ.name, new_source)
            if now == new_target:
                continue
            name = _link_text(new_target, occ, new_source, new_graph, new_files)
            out = out[: occ.name_start] + name + out[occ.name_end :]
            changed += 1
        if changed:
            edits.append(Edit(path, new_source, text, out, changed))
    return MovePlan(source, target, bool(by_path[source]["is_folder"]), tuple(edits), tuple(sorted(set(skipped))), tuple(sorted(drawings)))


def _safe_bytes(vault: Vault, rel: str) -> bytes:
    try:
        return vault.read_bytes(rel)
    except VaultError:
        return b"\0"


def apply(vault: Vault, move: MovePlan) -> None:
    for edit in move.edits:
        if vault.read_strict(edit.old_path) != edit.old_text:
            raise Stale(f"{edit.old_path} mudou no disco; veja a prévia de novo")
    if vault.exists(move.target) and not vault.is_case_only(move.source, move.target):
        raise Exists(f"já existe {move.target}")
    staging = Path(tempfile.mkdtemp(dir=vault.root, prefix=TMP_PREFIX))
    committed: list[Edit] = []
    moved = False
    try:
        staged = []
        for index, edit in enumerate(move.edits):
            temporary = staging / f"edit-{index}"
            temporary.write_bytes(edit.new_text.encode("utf-8"))
            shutil.copymode(vault.path(edit.old_path), temporary)
            staged.append((temporary, edit))
        vault.move(move.source, move.target)
        moved = True
        for temporary, edit in staged:
            vault.replace(temporary, vault.path(edit.new_path))
            committed.append(edit)
    except BaseException as error:
        failures = []
        for edit in committed:
            try:
                vault.write_bytes_atomic(vault.path(edit.new_path), edit.old_text.encode("utf-8"))
            except OSError:
                failures.append(edit.new_path)
        if moved:
            try:
                vault.move(move.target, move.source)
            except VaultError:
                failures.append(move.target)
        if failures:
            raise VaultError(
                "ERRO: a reversão não terminou. Confira o git do brain; estes itens podem estar alterados: "
                + ", ".join(failures) + f". Já gravados: {len(committed)} de {len(move.edits)} notas; "
                + ("a pasta ou nota já foi movida" if moved else "nada foi movido") + f". Causa original: {error}"
            ) from error
        raise VaultError(f"Nada foi alterado: não consegui aplicar a mudança ({error})") from error
    finally:
        shutil.rmtree(staging, ignore_errors=True)
