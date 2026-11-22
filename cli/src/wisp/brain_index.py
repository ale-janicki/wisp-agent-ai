import hashlib
import math
import os
import re
import sqlite3
import stat
import time
import unicodedata
from contextlib import closing
from dataclasses import dataclass, replace
from pathlib import Path, PurePosixPath

SKIP_DIRS = frozenset({".git", ".obsidian", ".trash", "arquivos"})
ATTACHMENT_SUFFIXES = frozenset(
    ".png .jpg .jpeg .gif .svg .webp .heic .pdf .mp3 .mp4 .mov .wav .m4a .webm .excalidraw .canvas .base".split()
)
SCHEMA = 3
BINARY_PROBE = 8192
CORRUPT_CODES = (11, 26)
BUSY_CODES = (5, 6)
BUSY_PAUSE = 0.02
INDEX_CAP = 128 * 1024
READ_CAP = 128 * 1024
BATCH = 100
MIN_TERM = 3
MAX_TERMS = 24
CANDIDATES = 100
BOOST_POOL = 10
NEIGHBOR_WEIGHT = 0.25
NEIGHBOR_CAP = 0.5
INDEGREE_WEIGHT = 0.15
INDEGREE_SCALE = math.log(20)
ACTIVE_BONUS = 0.1
HEAD_WEIGHT = 0.3
LOG_FACTOR = 0.4
LOG_MARKERS = ("sessions", "daily", "digest", "session", "log")
SNIPPET_WORDS = 30
LOCK_TIMEOUT = 5.0
WORDS = re.compile(r"[^\W_]+")
WIKILINK = re.compile(r"!?\[\[([^\[\]\n|]*)(?:\|[^\[\]\n]*)?\]\]")
HEADING = re.compile(r"^(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$")
INLINE_CODE = re.compile(r"`[^`\n]*`")
STOPWORDS = frozenset(
    "a o as os um uma uns umas de da do das dos em na no nas nos por para com sem sob sobre entre ate "
    "e ou mas que se como isso isto esse essa este esta ele ela eles elas meu minha seu sua nosso nossa "
    "the an of to in on at by for with from and or but not is are was were be been this that these those "
    "it its my your our their his her index hub notes note md".split()
)


class BrainError(Exception):
    pass


@dataclass(frozen=True)
class Parsed:
    title: str
    aliases: tuple[str, ...]
    tags: tuple[str, ...]
    status: str
    headings: tuple[tuple[int, str], ...]
    body: str
    links: tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class NoteRow:
    rel: str
    title: str
    stem: str
    aliases: tuple[str, ...]
    tags: tuple[str, ...] = ()
    status: str = ""


@dataclass(frozen=True)
class Link:
    name: str
    heading: str
    target: str | None


@dataclass(frozen=True)
class Hit:
    rel: str
    title: str
    link: str
    snippet: str
    score: float
    lex: float
    coverage: float = 1.0
    strong: float = 1.0
    mass: float = 99.0


@dataclass
class SyncStats:
    indexed: int = 0
    removed: int = 0
    partial: bool = False
    skipped: bool = False
    complete: bool = True


def fold(text: str) -> str:
    decomposed = unicodedata.normalize("NFKD", text.casefold())
    return "".join(c for c in decomposed if not unicodedata.combining(c))


def words(text: str) -> list[str]:
    return WORDS.findall(fold(text))


def query_terms(text: str) -> list[str]:
    seen: dict[str, None] = {}
    for word in words(text):
        if len(word) >= MIN_TERM and word not in STOPWORDS:
            seen.setdefault(word)
    return list(seen)[:MAX_TERMS]


def estimate_tokens(text: str) -> int:
    return (len(text) + 3) // 4


def split_frontmatter(text: str) -> tuple[str, str]:
    if not text.startswith("---"):
        return "", text
    end = text.find("\n---", 3)
    if end < 0:
        return "", text
    after = text.find("\n", end + 1)
    return text[3:end], text[after + 1 :] if after >= 0 else ""


def _unquote(value: str) -> str:
    return value.strip().strip("'\"").strip()


def parse_list(front: str, key: str) -> tuple[str, ...]:
    inline = re.search(rf"^{key}:[ \t]*\[(.*?)\]", front, re.M)
    if inline:
        return tuple(a for a in (_unquote(p) for p in inline.group(1).split(",")) if a)
    block = re.search(rf"^{key}:[ \t]*\n((?:[ \t]*-[ \t]*.*(?:\n|$))+)", front, re.M)
    if not block:
        return ()
    items = (_unquote(line.strip()[1:]) for line in block.group(1).splitlines())
    return tuple(a for a in items if a)


def parse_status(front: str) -> str:
    found = re.search(r"^status:[ \t]*(.*?)[ \t]*$", front, re.M)
    return fold(_unquote(found.group(1))) if found else ""


def _outside_fences(body: str) -> list[str]:
    kept: list[str] = []
    fence = None
    for line in body.splitlines():
        marker = line.lstrip()[:3]
        if fence is None and marker in ("```", "~~~"):
            fence = marker
            continue
        if fence is not None:
            if line.lstrip().startswith(fence):
                fence = None
            continue
        kept.append(line)
    return kept


def _link_parts(target: str) -> tuple[str, str] | None:
    name, _, heading = target.rstrip("\\").strip().partition("#")
    name, heading = name.strip(), heading.strip()
    if heading.startswith("^"):
        heading = ""
    if not name and not heading:
        return None
    if PurePosixPath(name).suffix.lower() in ATTACHMENT_SUFFIXES:
        return None
    return name, heading


def parse_note(text: str) -> Parsed:
    front, body = split_frontmatter(text)
    prose = _outside_fences(body)
    headings = tuple((len(m.group(1)), m.group(2)) for m in (HEADING.match(line) for line in prose) if m and m.group(2))
    title = next((h for level, h in headings if level == 1), "")
    links: dict[tuple[str, str], None] = {}
    for line in prose:
        for found in WIKILINK.finditer(INLINE_CODE.sub("", line)):
            parts = _link_parts(found.group(1))
            if parts:
                links.setdefault(parts)
    tags = tuple(fold(t.lstrip("#")) for t in parse_list(front, "tags"))
    return Parsed(title, parse_list(front, "aliases"), tags, parse_status(front), headings, body, tuple(links))


def read_prefix(path: Path, limit: int, strict: bool = False) -> tuple[str, bool] | None:
    try:
        if not stat.S_ISREG(path.stat().st_mode):
            return None
        with path.open("rb") as handle:
            data = handle.read(limit + 1)
    except OSError:
        if strict:
            raise
        return None
    if b"\0" in data[:BINARY_PROBE]:
        return None
    return data[:limit].decode("utf-8", errors="replace"), len(data) > limit


def section(text: str, heading: str) -> str | None:
    wanted = fold(heading)
    lines = text.splitlines()
    start, level, fence = None, 0, None
    for i, line in enumerate(lines):
        marker = line.lstrip()[:3]
        if fence is None and marker in ("```", "~~~"):
            fence = marker
            continue
        if fence is not None:
            fence = None if line.lstrip().startswith(fence) else fence
            continue
        match = HEADING.match(line)
        if not match:
            continue
        if start is None:
            if fold(match.group(2)) == wanted:
                start, level = i, len(match.group(1))
        elif len(match.group(1)) <= level:
            return "\n".join(lines[start:i]).strip()
    return "\n".join(lines[start:]).strip() if start is not None else None


def _stem_words(stem: str) -> str:
    return stem.replace("-", " ").replace("_", " ")


def _prefix_of(term: str) -> str:
    return term[: len(term) - 2] if len(term) >= 6 else term


def _prefix_term(term: str) -> str:
    if len(term) <= MIN_TERM:
        return f'"{term}"'
    return f'"{_prefix_of(term)}"*'


def match_expression(terms: list[str]) -> str:
    return " OR ".join(_prefix_term(t) for t in terms)


class Graph:
    def __init__(self, rows: list[NoteRow], links: dict[str, list[tuple[str, str]]]):
        self.notes = {row.rel: row for row in rows}
        self._heads: dict[str, frozenset[str]] = {}
        self._stem = self._table()
        self._alias = self._table()
        self._title = self._table()
        self._path = self._table()
        for row in rows:
            _put(self._stem, row.stem, row.rel)
            _put(self._title, row.title, row.rel)
            for alias in row.aliases:
                _put(self._alias, alias, row.rel)
            parts = row.rel[:-3].split("/")
            for i in range(len(parts)):
                _put(self._path, "/".join(parts[i:]), row.rel)
        self.outgoing: dict[str, list[Link]] = {}
        self.incoming: dict[str, list[str]] = {rel: [] for rel in self.notes}
        for src, pairs in links.items():
            if src not in self.notes:
                continue
            resolved = [Link(name, heading, self.resolve(name, src)) for name, heading in pairs]
            self.outgoing[src] = resolved
            for target in {link.target for link in resolved if link.target and link.target != src}:
                self.incoming[target].append(src)

    @staticmethod
    def _table() -> dict[str, dict[str, list[str]]]:
        return {"exact": {}, "folded": {}}

    def resolve(self, name: str, source: str | None = None) -> str | None:
        key = name.strip().removeprefix("./").lstrip("/")
        if key.casefold().endswith(".md"):
            key = key[:-3]
        if not key:
            return source
        tables = (self._path,) if "/" in key else (self._stem, self._alias, self._title)
        for table in tables:
            found = _find(table, key)
            if found:
                return self._closest(found, source)
        return None

    def resolve_rel(self, rel: str) -> str | None:
        key = rel[:-3] if rel.casefold().endswith(".md") else rel
        found = _find(self._path, key.lstrip("/"))
        return self._closest(found, None) if found else None

    @staticmethod
    def _closest(found: list[str], source: str | None) -> str:
        home = PurePosixPath(source).parent if source else None
        return min(found, key=lambda rel: (PurePosixPath(rel).parent != home, rel.count("/"), rel))

    def head_ratio(self, rel: str, terms: list[str]) -> float:
        heads = self._heads.get(rel)
        if heads is None:
            row = self.notes[rel]
            heads = self._heads[rel] = frozenset(words(" ".join([row.title, row.stem.replace("-", " "), *row.aliases])))
        found = sum(any(h.startswith(_prefix_of(t)) if len(t) > MIN_TERM else h == t for h in heads) for t in terms)
        return found / len(terms)

    def neighbors(self, rel: str) -> set[str]:
        out = {link.target for link in self.outgoing.get(rel, []) if link.target}
        return (out | set(self.incoming.get(rel, []))) - {rel}

    def link_name(self, rel: str) -> str:
        row = self.notes[rel]
        return row.stem if len(_find(self._stem, row.stem)) == 1 else rel[:-3]


def _put(table: dict[str, dict[str, list[str]]], key: str, rel: str) -> None:
    for level, form in (("exact", key.casefold()), ("folded", fold(key))):
        if not form:
            continue
        bucket = table[level].setdefault(form, [])
        if rel not in bucket:
            bucket.append(rel)


def _find(table: dict[str, dict[str, list[str]]], key: str) -> list[str]:
    return table["exact"].get(key.casefold()) or table["folded"].get(fold(key)) or []


def index_path(state: Path, root: Path) -> Path:
    digest = hashlib.sha1(str(root).encode("utf-8", "surrogateescape")).hexdigest()[:12]
    return state / "brain-index" / f"{digest}.sqlite3"


class BrainIndex:
    def __init__(self, root: Path, db_path: Path, lock_timeout: float = LOCK_TIMEOUT, log_markers: tuple[str, ...] = LOG_MARKERS):
        self.root = root.expanduser().resolve()
        self.db_path = db_path
        self.lock_timeout = lock_timeout
        self.log_markers = frozenset(fold(m) for m in log_markers)
        self._graph: Graph | None = None
        self._generation: str | None = None

    def _connect(self) -> sqlite3.Connection:
        self.db_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.db_path.parent.chmod(0o700)
        give_up = time.monotonic() + self.lock_timeout
        deleted = False
        while True:
            conn = sqlite3.connect(self.db_path, timeout=self.lock_timeout, isolation_level=None)
            try:
                self._prepare(conn)
                self._lock_down()
                return conn
            except sqlite3.DatabaseError as e:
                conn.close()
                code = getattr(e, "sqlite_errorcode", 0) & 0xFF
                if code in CORRUPT_CODES and not deleted:
                    deleted = True
                    for suffix in ("", "-wal", "-shm"):
                        Path(str(self.db_path) + suffix).unlink(missing_ok=True)
                elif isinstance(e, sqlite3.OperationalError) and code in BUSY_CODES and time.monotonic() < give_up:
                    time.sleep(BUSY_PAUSE)
                else:
                    raise

    def _lock_down(self) -> None:
        for suffix in ("", "-wal", "-shm"):
            try:
                Path(str(self.db_path) + suffix).chmod(0o600)
            except FileNotFoundError:
                pass

    def _prepare(self, conn: sqlite3.Connection) -> None:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        if conn.execute("PRAGMA user_version").fetchone()[0] == SCHEMA:
            return
        conn.execute("BEGIN IMMEDIATE")
        try:
            if conn.execute("PRAGMA user_version").fetchone()[0] != SCHEMA:
                self._reset(conn)
            conn.execute("COMMIT")
        except BaseException:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
            raise

    @staticmethod
    def _reset(conn: sqlite3.Connection) -> None:
        for statement in (
            "DROP TABLE IF EXISTS docs",
            "DROP TABLE IF EXISTS links",
            "DROP TABLE IF EXISTS files",
            "DROP TABLE IF EXISTS meta",
            """CREATE TABLE files(id INTEGER PRIMARY KEY, rel TEXT UNIQUE NOT NULL, mtime_ns INTEGER NOT NULL,
                size INTEGER NOT NULL, title TEXT NOT NULL, stem TEXT NOT NULL, aliases TEXT NOT NULL, tags TEXT NOT NULL,
                status TEXT NOT NULL, skip INTEGER NOT NULL DEFAULT 0)""",
            "CREATE TABLE links(src TEXT NOT NULL, name TEXT NOT NULL, heading TEXT NOT NULL)",
            "CREATE INDEX links_src ON links(src)",
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            """CREATE VIRTUAL TABLE docs USING fts5(rel UNINDEXED, title, aliases, headings, body,
                tokenize='unicode61 remove_diacritics 2')""",
            f"PRAGMA user_version={SCHEMA}",
        ):
            conn.execute(statement)

    def _inside(self, path: str) -> bool:
        return Path(os.path.realpath(path)).is_relative_to(self.root)

    def _scan(self) -> dict[str, tuple[int, int]]:
        found: dict[str, tuple[int, int]] = {}
        for current, dirs, names in os.walk(self.root):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith("."))
            for name in names:
                if not name.endswith(".md") or name.startswith("."):
                    continue
                full = os.path.join(current, name)
                try:
                    info = os.stat(full)
                    if not stat.S_ISREG(info.st_mode) or (os.path.islink(full) and not self._inside(full)):
                        continue
                    rel = Path(full).relative_to(self.root).as_posix()
                    rel.encode("utf-8")
                except (OSError, ValueError, UnicodeEncodeError):
                    continue
                found[rel] = (info.st_mtime_ns, info.st_size)
        return found

    def sync(self, deadline: float | None = None) -> SyncStats:
        stats = SyncStats()
        seen = self._scan()
        try:
            conn = self._connect()
        except sqlite3.OperationalError:
            return SyncStats(skipped=True, complete=False)
        with closing(conn):
            if self._diff(conn, seen) == ([], []) and self._complete(conn):
                return stats
            try:
                conn.execute("BEGIN IMMEDIATE")
            except sqlite3.OperationalError:
                return SyncStats(skipped=True, complete=self._complete(conn))
            try:
                stale, gone = self._diff(conn, seen)
                for rel in gone:
                    self._drop(conn, rel)
                    stats.removed += 1
                for count, rel in enumerate(stale, 1):
                    if deadline is not None and time.monotonic() > deadline:
                        stats.partial = True
                        break
                    if self._store(conn, rel, seen[rel]):
                        stats.indexed += 1
                    if count % BATCH == 0:
                        self._commit(conn)
                        try:
                            conn.execute("BEGIN IMMEDIATE")
                        except sqlite3.OperationalError:
                            stats.partial = True
                            break
                if not stats.partial:
                    conn.execute("INSERT OR REPLACE INTO meta VALUES('complete', '1')")
                if conn.in_transaction:
                    self._commit(conn)
            except BaseException:
                if conn.in_transaction:
                    conn.execute("ROLLBACK")
                raise
            stats.complete = self._complete(conn)
        return stats

    @staticmethod
    def _commit(conn: sqlite3.Connection) -> None:
        conn.execute("INSERT OR REPLACE INTO meta VALUES('generation', ?)", (str(time.time_ns()),))
        conn.execute("COMMIT")

    @staticmethod
    def _diff(conn: sqlite3.Connection, seen: dict[str, tuple[int, int]]) -> tuple[list[str], list[str]]:
        known = {rel: (m, s) for rel, m, s in conn.execute("SELECT rel, mtime_ns, size FROM files")}
        stale = sorted(rel for rel, stamp in seen.items() if known.get(rel) != stamp)
        gone = sorted(rel for rel in known if rel not in seen)
        return stale, gone

    @staticmethod
    def _complete(conn: sqlite3.Connection) -> bool:
        row = conn.execute("SELECT value FROM meta WHERE key = 'complete'").fetchone()
        return bool(row and row[0] == "1")

    @staticmethod
    def _drop(conn: sqlite3.Connection, rel: str) -> None:
        row = conn.execute("SELECT id FROM files WHERE rel = ?", (rel,)).fetchone()
        if row:
            conn.execute("DELETE FROM docs WHERE rowid = ?", (row[0],))
            conn.execute("DELETE FROM files WHERE id = ?", (row[0],))
        conn.execute("DELETE FROM links WHERE src = ?", (rel,))

    def _store(self, conn: sqlite3.Connection, rel: str, stamp: tuple[int, int]) -> bool:
        try:
            read = read_prefix(self.root / rel, INDEX_CAP, strict=True)
        except OSError:
            return False
        if read is None:
            self._drop(conn, rel)
            conn.execute(
                "INSERT INTO files(rel, mtime_ns, size, title, stem, aliases, tags, status, skip) VALUES(?,?,?,?,?,?,?,?,1)",
                (rel, stamp[0], stamp[1], "", PurePosixPath(rel).stem, "", "", ""),
            )
            return False
        parsed = parse_note(read[0])
        stem = PurePosixPath(rel).stem
        title = parsed.title or _stem_words(stem)
        self._drop(conn, rel)
        cursor = conn.execute(
            "INSERT INTO files(rel, mtime_ns, size, title, stem, aliases, tags, status) VALUES(?,?,?,?,?,?,?,?)",
            (rel, stamp[0], stamp[1], title, stem, "\n".join(parsed.aliases), "\n".join(parsed.tags), parsed.status),
        )
        conn.execute(
            "INSERT INTO docs(rowid, rel, title, aliases, headings, body) VALUES(?,?,?,?,?,?)",
            (
                cursor.lastrowid,
                rel,
                f"{title}\n{_stem_words(stem)}",
                "\n".join(parsed.aliases),
                "\n".join(h for _, h in parsed.headings),
                parsed.body,
            ),
        )
        conn.executemany("INSERT INTO links VALUES(?,?,?)", [(rel, name, heading) for name, heading in parsed.links])
        return True

    def graph(self) -> Graph:
        with closing(self._connect()) as conn:
            row = conn.execute("SELECT value FROM meta WHERE key = 'generation'").fetchone()
            generation = row[0] if row else ""
            if self._graph is not None and generation == self._generation:
                return self._graph
            rows = [
                NoteRow(rel, title, stem, tuple(a for a in aliases.split("\n") if a), tuple(t for t in tags.split("\n") if t), status)
                for rel, title, stem, aliases, tags, status in conn.execute(
                    "SELECT rel, title, stem, aliases, tags, status FROM files WHERE skip = 0 ORDER BY rel"
                )
            ]
            links: dict[str, list[tuple[str, str]]] = {}
            for src, name, heading in conn.execute("SELECT src, name, heading FROM links ORDER BY rowid"):
                links.setdefault(src, []).append((name, heading))
        self._graph, self._generation = Graph(rows, links), generation
        return self._graph

    def is_log(self, row: NoteRow) -> bool:
        folders = {fold(part) for part in PurePosixPath(row.rel).parent.parts}
        return bool(self.log_markers & (folders | set(row.tags)))

    def stats(self) -> dict[str, int]:
        with closing(self._connect()) as conn:
            notes = conn.execute("SELECT count(*) FROM files WHERE skip = 0").fetchone()[0]
            links = conn.execute("SELECT count(*) FROM links").fetchone()[0]
        size = sum(Path(str(self.db_path) + s).stat().st_size for s in ("", "-wal") if Path(str(self.db_path) + s).exists())
        return {"notes": notes, "links": links, "bytes": size}

    def search(self, query: str, limit: int = 10, evidence: bool = False) -> list[Hit]:
        terms = query_terms(query)
        if not terms:
            return []
        graph = self.graph()
        with closing(self._connect()) as conn:
            try:
                rows = conn.execute(
                    "SELECT rel, bm25(docs, 0.0, 10.0, 8.0, 4.0, 1.0), snippet(docs, -1, '', '', '…', ?) "
                    "FROM docs WHERE docs MATCH ? ORDER BY 2 LIMIT ?",
                    (SNIPPET_WORDS, match_expression(terms), CANDIDATES),
                ).fetchall()
            except sqlite3.OperationalError as e:
                raise BrainError(f"busca inválida: {e}") from None
        rows = [(rel, max(-score, 0.0), snip) for rel, score, snip in rows if rel in graph.notes]
        if not rows:
            return []
        peak = max(lex for _, lex, _ in rows) or 1.0
        normal = {rel: lex / peak for rel, lex, _ in rows}
        pool = sorted(normal, key=normal.get, reverse=True)[:BOOST_POOL]
        hits = []
        for rel, lex, snip in rows:
            near = graph.neighbors(rel)
            boost = min(NEIGHBOR_CAP, NEIGHBOR_WEIGHT * sum(normal[t] for t in pool if t in near))
            row = graph.notes[rel]
            prior = INDEGREE_WEIGHT * min(1.0, math.log1p(len(graph.incoming.get(rel, []))) / INDEGREE_SCALE)
            canon = HEAD_WEIGHT * graph.head_ratio(rel, terms) + (ACTIVE_BONUS if row.status == "active" else 0.0)
            score = (normal[rel] + boost + prior + canon) * (LOG_FACTOR if self.is_log(row) else 1.0)
            hits.append(Hit(rel, row.title, graph.link_name(rel), " ".join(snip.split()), round(score, 4), round(lex, 6)))
        hits.sort(key=lambda h: (-h.score, h.rel))
        hits = hits[:limit]
        return self._with_evidence(terms, hits, graph) if evidence else hits

    def _with_evidence(self, terms: list[str], hits: list[Hit], graph: Graph) -> list[Hit]:
        if not hits:
            return hits
        ids = {}
        with closing(self._connect()) as conn:
            marks = ",".join("?" * len(hits))
            for rowid, rel in conn.execute(f"SELECT id, rel FROM files WHERE rel IN ({marks})", [h.rel for h in hits]):
                ids[rel] = rowid
            total = len(graph.notes)
            weight: dict[str, float] = {}
            anywhere: dict[str, set[int]] = {}
            headline: dict[str, set[int]] = {}
            pool = ",".join(str(i) for i in ids.values())
            for term in terms:
                expr = _prefix_term(term)
                df = conn.execute("SELECT count(*) FROM docs WHERE docs MATCH ?", (expr,)).fetchone()[0]
                if not df:
                    continue
                weight[term] = math.log1p(total / df)
                anywhere[term] = {r[0] for r in conn.execute(f"SELECT rowid FROM docs WHERE docs MATCH ? AND rowid IN ({pool})", (expr,))}
                head = "{title aliases} : " + expr
                headline[term] = {r[0] for r in conn.execute(f"SELECT rowid FROM docs WHERE docs MATCH ? AND rowid IN ({pool})", (head,))}
        mass = sum(weight.values()) or 1.0
        out = []
        for hit in hits:
            rowid = ids.get(hit.rel)
            seen = sum(w for t, w in weight.items() if rowid in anywhere[t]) / mass
            gained = sum(w for t, w in weight.items() if rowid in headline[t])
            out.append(replace(hit, coverage=round(seen, 4), strong=round(gained / mass, 4), mass=round(gained, 3)))
        return out

    def resolve_ref(self, ref: str) -> tuple[str, str] | None:
        graph = self.graph()
        text = ref.strip()
        if text.startswith("[[") and text.endswith("]]"):
            text = text[2:-2]
        target, _, _alias = text.partition("|")
        name, _, heading = target.strip().partition("#")
        name, heading = name.strip(), ("" if heading.startswith("^") else heading.strip())
        if not name:
            return None
        if name.startswith(("/", "~")):
            real = Path(os.path.realpath(os.path.expanduser(name)))
            if not real.is_relative_to(self.root):
                return None
            rel = graph.resolve_rel(real.relative_to(self.root).as_posix())
        else:
            rel = graph.resolve_rel(name) if "/" in name or name.casefold().endswith(".md") else None
            rel = rel or graph.resolve(name)
        return (rel, heading) if rel else None

    def read_note(self, rel: str, limit: int = READ_CAP) -> tuple[str, bool]:
        full = self.root / rel
        if not self._inside(str(full)):
            raise BrainError("a nota está fora do brain")
        read = read_prefix(full, limit)
        if read is None:
            raise BrainError(f"não consegui ler {rel}")
        return read

    def walk(self, rel: str, depth: int) -> tuple[list[tuple[str, int, str]], list[tuple[str, str]]]:
        graph = self.graph()
        order = [(rel, 0, "root")]
        reached = {rel}
        frontier = [rel]
        for level in range(1, depth + 1):
            following = []
            for node in frontier:
                steps = [(t.target, "out") for t in graph.outgoing.get(node, []) if t.target]
                steps += [(src, "in") for src in graph.incoming.get(node, [])]
                for target, direction in steps:
                    if target not in reached:
                        reached.add(target)
                        order.append((target, level, direction))
                        following.append(target)
            frontier = following
        broken = [(node, link.name) for node, _, _ in order for link in graph.outgoing.get(node, []) if link.target is None]
        return order, broken
