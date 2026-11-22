import json
import sqlite3
import sys
from pathlib import Path

from wisp.brain_index import BrainError, BrainIndex, index_path
from wisp.config import WispConfig
from wisp.paths import WispPaths

MAX_LIMIT = 50


def run_search(query: str, root: str | None, limit: int, cfg: WispConfig, paths: WispPaths) -> int:
    base = root or cfg.brain
    if not base or not Path(base).expanduser().is_dir():
        print("o brain não está configurado ou a pasta não existe", file=sys.stderr)
        return 1
    folder = Path(base).expanduser().resolve()
    index = BrainIndex(folder, index_path(paths.state, folder), log_markers=tuple(cfg.brain_log_markers))
    try:
        index.sync()
        hits = index.search(query, max(1, min(MAX_LIMIT, limit)))
    except (BrainError, sqlite3.Error, OSError) as e:
        print(f"não consegui buscar no brain: {e}", file=sys.stderr)
        return 1
    rows = [{"path": h.rel, "title": h.title, "snippet": h.snippet, "score": h.score} for h in hits]
    print(json.dumps(rows, ensure_ascii=False))
    return 0
