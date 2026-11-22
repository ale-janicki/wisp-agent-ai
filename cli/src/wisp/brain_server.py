import json
import sqlite3
from collections.abc import Callable
from pathlib import Path

from mcp.server.mcpserver import MCPServer
from mcp.types import CallToolResult, TextContent

from wisp.brain_index import BrainError, BrainIndex, index_path, section
from wisp.config import WispConfig
from wisp.paths import WispPaths

SERVER_NAME = "wisp-brain"
TOOLS = ("brain_search", "brain_read", "brain_links")
DEFAULT_LIMIT = 10
MAX_LIMIT = 30
MAX_DEPTH = 3
MAX_NODES = 100
MAX_BROKEN = 50
SUGGESTIONS = 5
DB_FAILURE = "o índice do brain está ocupado ou danificado agora; tente de novo em instantes"


class ToolFailure(Exception):
    pass


def open_index(cfg: WispConfig, paths: WispPaths) -> BrainIndex:
    if not cfg.brain or not Path(cfg.brain).expanduser().is_dir():
        raise ToolFailure("o brain não está configurado ou a pasta não existe")
    root = Path(cfg.brain).expanduser().resolve()
    return BrainIndex(root, index_path(paths.state, root), log_markers=tuple(cfg.brain_log_markers))


def _fresh(index: BrainIndex) -> None:
    try:
        _guard(index.sync)
    except OSError as e:
        raise ToolFailure(f"não consegui atualizar o índice do brain: {e.strerror or type(e).__name__}") from None


def _guard(call: Callable):
    try:
        return call()
    except BrainError as e:
        raise ToolFailure(str(e)) from None
    except sqlite3.Error:
        raise ToolFailure(DB_FAILURE) from None


def _clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, int(value)))


def brain_search(index: BrainIndex, query: str, limit: int = DEFAULT_LIMIT) -> list[dict]:
    _fresh(index)
    hits = _guard(lambda: index.search(query, _clamp(limit, 1, MAX_LIMIT)))
    return [
        {"path": h.rel, "link": f"[[{h.link}]]", "title": h.title, "snippet": h.snippet, "score": h.score} for h in hits
    ]


def _missing(index: BrainIndex, ref: str) -> ToolFailure:
    near = [f"[[{h.link}]]" for h in index.search(ref, SUGGESTIONS)]
    hint = f" Parecidas: {', '.join(near)}." if near else ""
    return ToolFailure(f"não achei a nota {ref!r} no brain.{hint}")


def brain_read(index: BrainIndex, path_or_title: str) -> dict:
    _fresh(index)
    found = index.resolve_ref(path_or_title)
    if found is None:
        raise _missing(index, path_or_title)
    rel, heading = found
    graph = index.graph()
    text, truncated = _guard(lambda: index.read_note(rel))
    content, heading_found = text, None
    if heading:
        extract = section(text, heading)
        heading_found = extract is not None
        content = extract if extract is not None else text
    row = graph.notes[rel]
    return {
        "path": rel,
        "link": f"[[{graph.link_name(rel)}]]",
        "title": row.title,
        "aliases": list(row.aliases),
        "heading": heading or None,
        "heading_found": heading_found,
        "truncated": truncated,
        "content": content,
        "links": [
            {
                "name": link.name or row.stem,
                "heading": link.heading or None,
                "path": link.target,
                "title": graph.notes[link.target].title if link.target else None,
            }
            for link in graph.outgoing.get(rel, [])
        ],
        "backlinks": [{"path": src, "link": f"[[{graph.link_name(src)}]]", "title": graph.notes[src].title} for src in graph.incoming.get(rel, [])],
    }


def brain_links(index: BrainIndex, note: str, depth: int = 1) -> dict:
    _fresh(index)
    found = index.resolve_ref(note)
    if found is None:
        raise _missing(index, note)
    graph = index.graph()
    order, broken = index.walk(found[0], _clamp(depth, 1, MAX_DEPTH))
    return {
        "root": found[0],
        "nodes": [
            {"path": rel, "link": f"[[{graph.link_name(rel)}]]", "title": graph.notes[rel].title, "depth": level, "via": via}
            for rel, level, via in order[:MAX_NODES]
        ],
        "truncated": len(order) > MAX_NODES,
        "broken": [{"from": src, "name": name} for src, name in broken[:MAX_BROKEN]],
    }


def _failure(e: ToolFailure) -> CallToolResult:
    return CallToolResult(content=[TextContent(type="text", text=str(e))], is_error=True)


def _reply(call: Callable) -> CallToolResult:
    try:
        return CallToolResult(content=[TextContent(type="text", text=json.dumps(call(), ensure_ascii=False))])
    except ToolFailure as e:
        return _failure(e)
    except sqlite3.Error:
        return _failure(ToolFailure(DB_FAILURE))


def build_server(open_brain: Callable[[], BrainIndex]) -> MCPServer:
    server = MCPServer(SERVER_NAME)

    @server.tool(
        name="brain_search",
        description="Busca no brain do usuário (título, apelidos, títulos de seção e texto, com reforço pelos wikilinks). "
        "Devolve caminho, título, trecho e nota de relevância; use [[link]] para citar",
    )
    def _search(query: str, limit: int = DEFAULT_LIMIT) -> CallToolResult:
        return _reply(lambda: brain_search(open_brain(), query, limit))

    @server.tool(
        name="brain_read",
        description="Lê uma nota do brain por caminho, nome, apelido ou [[wikilink]] (aceita #seção e |texto). "
        "Devolve o conteúdo, os links de saída e os backlinks",
    )
    def _read(path_or_title: str) -> CallToolResult:
        return _reply(lambda: brain_read(open_brain(), path_or_title))

    @server.tool(
        name="brain_links",
        description="Percorre o grafo de wikilinks do brain a partir de uma nota (saída e entrada), até a profundidade pedida (máx. 3)",
    )
    def _links(note: str, depth: int = 1) -> CallToolResult:
        return _reply(lambda: brain_links(open_brain(), note, depth))

    return server


def run_server(cfg: WispConfig, paths: WispPaths) -> int:
    opened: list[BrainIndex] = []

    def open_brain() -> BrainIndex:
        if not opened:
            opened.append(open_index(cfg, paths))
        return opened[0]

    build_server(open_brain).run("stdio")
    return 0
