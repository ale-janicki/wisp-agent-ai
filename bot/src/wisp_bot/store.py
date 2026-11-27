from __future__ import annotations
import contextlib, json, os, threading, time, uuid
from dataclasses import dataclass, asdict, field
from pathlib import Path

from . import compat
from .config import CURRENT as _CFG
from .transcript import stamp

STORE = _CFG.state_dir / "topics.json"
CURSOR = "espelhado_ate"


@contextlib.contextmanager
def file_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path.with_name(path.name + ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        compat.lock_file(fd)
        yield
    finally:
        os.close(fd)


@dataclass
class Topic:
    key: str
    name: str
    session_id: str
    cwd: str
    started: bool = False
    turns: int = 0
    cost: float = 0.0
    last_used: float = 0.0
    born: float = 0.0
    meta: dict = field(default_factory=dict)
    conversation: str = ""


class Store:
    def __init__(self, path: Path = STORE):
        self.path = path
        self._lock = threading.Lock()
        self._data: dict[str, Topic] = {}
        self._known: dict[str, str] = {}
        self._mtime = 0
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            raw = json.loads(self.path.read_text("utf-8"))
        except (json.JSONDecodeError, OSError):
            return
        self._data = {k: Topic(**v) for k, v in raw.items()}
        self._known = {k: t.conversation for k, t in self._data.items()}
        self._mtime = self._stat()

    def _stat(self) -> int:
        try:
            return self.path.stat().st_mtime_ns
        except OSError:
            return 0

    def _adopt_external(self) -> None:
        if self._stat() == self._mtime:
            return
        try:
            raw = json.loads(self.path.read_text("utf-8"))
        except (json.JSONDecodeError, OSError):
            return
        for key, value in raw.items():
            topic = self._data.get(key)
            disk = str(value.get("conversation") or "") if isinstance(value, dict) else ""
            if topic is not None and disk and disk != self._known.get(key, ""):
                topic.conversation = disk
                self._known[key] = disk
                if value.get("meta", {}).get(CURSOR) and CURSOR not in topic.meta:
                    topic.meta[CURSOR] = value["meta"][CURSOR]
        self._mtime = self._stat()

    def _flush(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with file_lock(self.path):
            self._mtime = 0
            self._adopt_external()
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps({k: asdict(v) for k, v in self._data.items()},
                                      indent=2, ensure_ascii=False), "utf-8")
            tmp.replace(self.path)
            self._known = {k: t.conversation for k, t in self._data.items()}
            self._mtime = self._stat()

    def get_or_create(self, key: str, name: str, cwd: str, meta: dict | None = None) -> Topic:
        with self._lock:
            t = self._data.get(key)
            if t is None:
                m = dict(meta or {})
                m.setdefault("criado", time.time())
                m.setdefault(CURSOR, stamp())
                t = Topic(key=key, name=name, session_id=str(uuid.uuid4()), cwd=cwd,
                          meta=m, conversation=str(uuid.uuid4()))
                self._data[key] = t
                self._flush()
            return t

    def renomear(self, key: str, name: str) -> bool:
        with self._lock:
            t = self._data.get(key)
            if t is None:
                return False
            if t.name != name:
                t.name = name
                self._flush()
            return True

    def set_conversation(self, key: str, conversation: str) -> None:
        with self._lock:
            t = self._data.get(key)
            if t is not None and t.conversation != conversation:
                t.conversation = conversation
                t.meta.setdefault(CURSOR, stamp())
                self._flush()

    def set_meta(self, key: str, **campos) -> None:
        with self._lock:
            t = self._data.get(key)
            if t is None:
                return
            for k, v in campos.items():
                if v is None:
                    t.meta.pop(k, None)
                else:
                    t.meta[k] = v
            self._flush()

    def get(self, key: str) -> Topic | None:
        with self._lock:
            self._adopt_external()
            return self._data.get(key)

    def mark_started(self, key: str) -> None:
        with self._lock:
            if key in self._data and not self._data[key].started:
                self._data[key].started = True
                self._flush()

    def bump(self, key: str, cost: float | None) -> None:
        with self._lock:
            t = self._data.get(key)
            if t is None:
                return
            t.turns += 1
            t.cost += float(cost or 0.0)
            t.last_used = time.time()
            if not t.born:
                t.born = t.last_used
            self._flush()

    def set_cwd(self, key: str, cwd: str) -> None:
        with self._lock:
            if key in self._data:
                self._data[key].cwd = cwd
                self._flush()

    def reset(self, key: str) -> None:
        with self._lock:
            if key in self._data:
                self._data[key].session_id = str(uuid.uuid4())
                self._data[key].started = False
                self._data[key].turns = 0
                self._data[key].cost = 0.0
                self._data[key].born = 0.0
                self._data[key].last_used = time.time()
                self._flush()

    def renovar_sessao(self, key: str) -> Topic | None:
        with self._lock:
            t = self._data.get(key)
            if t is None:
                return None
            t.session_id = str(uuid.uuid4())
            t.started = False
            self._flush()
            return t

    def adotar_sessao(self, key: str, session_id: str) -> None:
        with self._lock:
            t = self._data.get(key)
            if t:
                t.session_id = session_id
                t.started = True
                t.turns = max(t.turns, 1)
                self._flush()

    def seguir_sessao(self, key: str, session_id: str, started: bool,
                      born: float = 0.0, last_used: float = 0.0) -> None:
        with self._lock:
            t = self._data.get(key)
            if t:
                t.session_id = session_id
                t.started = started
                t.turns = max(t.turns, 1) if started else 0
                t.born = born if started else 0.0
                t.last_used = last_used or t.last_used
                self._flush()

    def drop(self, key: str) -> Topic | None:
        with self._lock:
            t = self._data.pop(key, None)
            if t:
                self._flush()
            return t

    def all(self) -> list[Topic]:
        with self._lock:
            self._adopt_external()
            return list(self._data.values())
