import json
import logging
import os
import re
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

import anyio.to_thread
from wisp_bot import transcript
from wisp_bot.broker import Broker

from wisp.config import WispConfig
from wisp.local import catalog as catalogs
from wisp.local import guardrails, modelos
from wisp.local.approver import Approver, DenyApprover
from wisp.local.guardrails import GuardrailsError, TurnGuard
from wisp.local.prompt import neutralize_context, system_prompt, today_note
from wisp.local.backend import Backend, BackendError, make_backend
from wisp.local.web import WebClient
from wisp.local.tools import Files, ToolFailure, ToolHost, ServerSpec, load_servers, open_host, with_approval_socket
from wisp.paths import WispPaths

ENGINE = "local"
CHARS_PER_TOKEN = 3
INPUT_SHARE = 0.75
OLD_RESULT_CHARS = 300
HISTORY_KEEP_SHARE = 0.6
FOREIGN_REPLY_TOKENS = 600
RESULT_CHARS = 8000
FILES_KEY = "conteúdo dos arquivos que o comando executa"
QUERY_FREE_CHARS = 120
LEAVES_TURN_CLEAN = frozenset({"web_search", "list_files", "write_file"})
PRIVATE_MARK = ".private"
LEAKY_FIELDS = {"mac_open_url": ("url", "busca", "site", "navegador"), "mac_open": ("alvo",)}
URL_LIKE = re.compile(r"^(?:[a-z][a-z0-9+.-]*://|mailto:|[\w-]+(?:\.[\w-]+)+(?:[/?#:]|$))", re.I)
log = logging.getLogger(__name__)
URL = re.compile(r"https?://[^\s<>\"']+")
URL_TAIL = ".,;:!?)]}"

Emit = Callable[[dict], None]


class EngineError(Exception):
    pass


@dataclass
class Session:
    conversation: str
    model: str
    mode: str
    messages: list[dict] = field(default_factory=list)
    private: bool = False


@dataclass
class TurnResult:
    text: str
    stopped: str | None
    steps: int
    model: str
    is_error: bool = False


def typed_urls(text: str) -> set[str]:
    found = URL.findall(text)
    return set(found) | {u.rstrip(URL_TAIL) for u in found}


def estimate_tokens(*parts: object) -> int:
    return sum(len(p if isinstance(p, str) else json.dumps(p, ensure_ascii=False, default=str)) for p in parts) // CHARS_PER_TOKEN + 1


def _unit_starts(messages: list[dict]) -> list[int]:
    return [i for i, m in enumerate(messages) if m.get("role") == "user"]


def fit_context(system: str, tools: list[dict], messages: list[dict], context_tokens: int) -> tuple[list[dict], bool] | None:
    budget = int(context_tokens * INPUT_SHARE)
    fixed = estimate_tokens(system, tools)
    kept = [dict(m) for m in messages]
    dropped = False

    def total() -> int:
        return fixed + estimate_tokens(kept)

    def shorten(upto: int) -> None:
        for m in kept[:upto]:
            if m.get("role") == "tool" and len(m.get("content", "")) > OLD_RESULT_CHARS:
                m["content"] = m["content"][:OLD_RESULT_CHARS] + "…"

    starts = _unit_starts(kept)
    shorten(starts[-1] if starts else 0)
    while total() > budget:
        starts = _unit_starts(kept)
        if len(starts) < 2:
            break
        del kept[: starts[1]]
        dropped = True
    if total() > budget:
        shorten(len(kept))
    if total() > budget:
        return None
    return kept, dropped


def trim_history(messages: list[dict], budget: int) -> list[dict]:
    starts = _unit_starts(messages)
    if len(starts) < 2:
        return messages
    bounds = [0, *starts[1:], len(messages)]
    sizes = [estimate_tokens(messages[a:b]) for a, b in zip(bounds, bounds[1:])]
    first, total = 0, 0
    for last, size in enumerate(sizes):
        total += size
        if total <= budget:
            continue
        while first < last and total > budget * HISTORY_KEEP_SHARE:
            total -= sizes[first]
            first += 1
    return messages[bounds[first]:]


def shorten_foreign(text: str) -> str:
    limit = FOREIGN_REPLY_TOKENS * CHARS_PER_TOKEN
    return text if len(text) <= limit else text[:limit].rstrip() + "…"


def leaks(name: str, session: Session, arguments: dict) -> bool:
    fields = LEAKY_FIELDS.get(name)
    if not fields:
        return False
    if session.private:
        return True
    for field_name in fields:
        value = arguments.get(field_name)
        if value is None:
            continue
        if not isinstance(value, str) or len(value) > QUERY_FREE_CHARS:
            return True
        if name == "mac_open" and URL_LIKE.match(value.strip()) and not Path(os.path.expanduser(value.strip())).exists():
            return True
    return False


def history_from(path: Path) -> list[dict]:
    return [
        {"role": e["kind"], "content": shorten_foreign(e["text"]) if e["kind"] == "assistant" and e.get("engine") != ENGINE else e["text"]}
        for e in transcript.read_entries(path)
        if e["kind"] in ("user", "assistant") and isinstance(e.get("text"), str) and e["text"].strip()
    ]


def read_private_tool(messages: list[dict]) -> bool:
    return any(m.get("role") == "tool" and m.get("tool_name") not in LEAVES_TURN_CLEAN for m in messages)


class LocalEngine:
    def __init__(
        self,
        folder: Path,
        cfg: WispConfig,
        paths: WispPaths,
        backend: Backend | None = None,
        *,
        servers: list[ServerSpec] | None = None,
        approver: Approver | None = None,
        thread: int | None = None,
        open_tools=open_host,
        web: WebClient | None = None,
        catalog: catalogs.Catalog | None = None,
        today: Callable[[], date] = date.today,
        new_id: Callable[[], str] = lambda: uuid.uuid4().hex[:12],
    ):
        self.folder, self.cfg, self.paths = folder, cfg, paths
        self.servers = servers
        self.approver = approver or DenyApprover()
        self.thread = thread
        self.open_tools = open_tools
        self.web = web
        self.catalog = catalog or catalogs.load()
        self.today = today
        self.new_id = new_id
        self.backend = backend or make_backend(folder, modelos.read(folder), self.catalog)

    def _model(self, wanted: str | None) -> str:
        model = wanted or modelos.read(self.folder).ativo
        if not model:
            raise EngineError("nenhum modelo local está ativo; escolha um em Ajustes > Modelo")
        return model

    def start(self, conversation: str | None = None, model: str | None = None, mode: str = "default") -> Session:
        guardrails.load(self.folder)
        if conversation is not None and not transcript.ID.match(conversation):
            raise EngineError(f"identificador de conversa inválido: {conversation!r}")
        session = Session(conversation or str(uuid.uuid4()), self._model(model), self._mode(mode))
        if conversation is None:
            self._mark_path(session.conversation).unlink(missing_ok=True)
        else:
            session.private = self._mark_path(conversation).exists()
        return session

    def resume(self, conversation: str, model: str | None = None, mode: str = "default") -> Session:
        guardrails.load(self.folder)
        path = self.folder / "conversas" / f"{conversation}.jsonl"
        if not transcript.ID.match(conversation) or not path.is_file():
            raise EngineError(f"não achei a conversa {conversation} em conversas/")
        history = history_from(path)
        session = Session(conversation, self._model(model), self._mode(mode), history, self._mark_path(conversation).exists())
        if not session.private and read_private_tool(history):
            self._mark_private(session)
        return session

    def _mark_path(self, conversation: str) -> Path:
        if not transcript.ID.match(conversation):
            raise EngineError(f"identificador de conversa inválido: {conversation!r}")
        return self.folder / "conversas" / f"{conversation}{PRIVATE_MARK}"

    def _mark_private(self, session: Session) -> None:
        session.private = True
        if not transcript.ID.match(session.conversation):
            return
        path = self._mark_path(session.conversation)
        try:
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.close(os.open(path, os.O_WRONLY | os.O_CREAT, 0o600))
        except OSError as e:
            log.warning("não consegui gravar a marca de conversa privada (%s); esta sessão segue privada só na memória", e)

    @staticmethod
    def _mode(mode: str) -> str:
        if mode not in guardrails.MODES:
            raise EngineError(f"modo de permissão desconhecido: {mode}")
        return mode

    def _roots(self) -> list[Path]:
        roots = [self.folder]
        if self.cfg.brain:
            roots.append(Path(self.cfg.brain).expanduser())
        return roots

    async def send(self, session: Session, text: str, emit: Emit, *, model: str | None = None) -> TurnResult:
        if model:
            session.model = model
        try:
            rails = guardrails.load(self.folder)
        except GuardrailsError as e:
            return self._fail(session, emit, str(e))
        tier = rails.tier(self.catalog.tier_of(session.model))
        guard = TurnGuard(tier, rails.repeat_limit)
        emit({"type": "system", "subtype": "init", "session_id": session.conversation, "model": session.model,
              "apiKeySource": "none", "permissionMode": session.mode, "engine": ENGINE, "tier": tier.name})
        try:
            await anyio.to_thread.run_sync(self.backend.ensure_running, session.model)
            servers, problems = (self.servers, []) if self.servers is not None else load_servers(self.folder)
            broker = await Broker().start()
            try:
                servers = [with_approval_socket(server, broker.path) for server in servers]
                async with self.open_tools(servers, self._roots(), self.folder, self.thread, web=self.web) as host:
                    host.authorize = broker.autorizar
                    return await self._loop(session, text, emit, rails, guard, host, problems)
            finally:
                await broker.close()
        except BackendError as e:
            return self._fail(session, emit, str(e))

    def _fail(self, session: Session, emit: Emit, message: str) -> TurnResult:
        emit({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": message}]}})
        self._result(session, emit, message, "error", 0, [], is_error=True)
        return TurnResult(message, "error", 0, session.model, True)

    def _result(self, session: Session, emit: Emit, text: str, stopped: str | None, steps: int, denials: list[str],
                is_error: bool = False) -> None:
        emit({"type": "result", "subtype": "error" if is_error else "success", "session_id": session.conversation,
              "result": text, "is_error": is_error, "permission_denials": [{"tool_name": d} for d in denials],
              "engine": ENGINE, "model": session.model, "stopped": stopped, "steps": steps})

    def _stop_note(self, why: str, session: Session, guard: TurnGuard, repeated: str = "") -> str:
        tier, tag = guard.tier, session.model
        suggestion = self.catalog.suggestion(tag)
        if why == "step_cap":
            return f"Parei depois de {guard.steps} passos: esse tamanho de modelo ({tier.label}) tem esse limite por resposta. {suggestion}"
        if why == "loop":
            return f"Parei porque repeti a mesma ação ({repeated}) {guard.repeat_limit} vezes sem avançar. {suggestion}"
        name = (self.catalog.find(tag).name if self.catalog.find(tag) else tag)
        return f"A conversa ficou grande demais para o {name} (limite de {self.catalog.context_of(tag)} tokens). {suggestion}"

    async def _loop(self, session: Session, text: str, emit: Emit, rails: guardrails.Guardrails, guard: TurnGuard,
                    host: ToolHost, problems: list[str]) -> TurnResult:
        tier, tag = guard.tier, session.model
        available = [s for name, s in host.specs.items() if guard.allowed(name)]
        tools = [s.for_chat() for s in available]
        system = system_prompt(self.folder, self.cfg, tier, [s.name for s in available], self.catalog.find(tag), tag)
        log.debug("prompt estimate: system %d + tools %d tokens", estimate_tokens(system), estimate_tokens(tools))
        context = self.catalog.context_of(tag)
        host.trusted_urls.update(typed_urls(text))
        turn: list[dict] = [{"role": "user", "content": f"{today_note(self.today())}\n{text}"}]
        history = trim_history(session.messages, tier.history_tokens)
        denials: list[str] = []
        notes = [*problems, *host.problems]
        last_text = ""
        stopped: str | None = None
        forgot = False
        while True:
            fitted = fit_context(system, tools, history + turn, context)
            if fitted is None:
                stopped = "context"
                break
            window, dropped = fitted
            forgot = forgot or dropped
            try:
                reply = await anyio.to_thread.run_sync(
                    lambda: self.backend.chat(tag, [{"role": "system", "content": system}, *window], tools, {"num_ctx": context}))
            except BackendError as e:
                return self._fail(session, emit, str(e))
            guard.count_step()
            content = [{"type": "thinking", "thinking": ""}] if reply.thinking else []
            calls = [(c.get("function") or {}) for c in reply.tool_calls]
            calls = [{"id": f"toolu_local_{self.new_id()}", "name": c.get("name", ""), "arguments": c.get("arguments") or {}} for c in calls]
            if reply.content.strip():
                content.append({"type": "text", "text": reply.content.strip()})
                last_text = reply.content.strip()
            content += [{"type": "tool_use", "id": c["id"], "name": c["name"], "input": c["arguments"]} for c in calls]
            if content:
                emit({"type": "assistant", "message": {"role": "assistant", "content": content}})
            assistant = {"role": "assistant", "content": reply.content}
            if calls:
                assistant["tool_calls"] = [{"id": c["id"], "function": {"name": c["name"], "arguments": c["arguments"]}} for c in calls]
            turn.append(assistant)
            if not calls:
                break
            for index, call in enumerate(calls):
                if await self._run_call(session, emit, rails, guard, host, call, denials, turn) == "loop":
                    stopped = "loop"
                    turn += [{"role": "tool", "tool_name": c["name"], "tool_call_id": c["id"], "content": "não executei: o turno foi interrompido"} for c in calls[index:]]
                    break
            if stopped:
                break
            if guard.capped:
                stopped = "step_cap"
                break
        session.messages.extend(turn)
        return self._finish(session, emit, guard, stopped, last_text, notes, forgot, denials)

    def _finish(self, session: Session, emit: Emit, guard: TurnGuard, stopped: str | None, last_text: str,
                notes: list[str], forgot: bool, denials: list[str]) -> TurnResult:
        extra = list(notes)
        if stopped:
            extra.insert(0, self._stop_note(stopped, session, guard, guard.last_repeated))
        if guard.refused:
            extra.append(f"Neste tamanho de modelo ({guard.tier.label}) não posso usar: {', '.join(guard.refused)}. {self.catalog.suggestion(session.model)}")
        if forgot:
            extra.append(f"Esqueci as mensagens mais antigas: este modelo só guarda {self.catalog.context_of(session.model)} tokens.")
        final = last_text
        if extra:
            note = "\n".join(f"↳ {line}" for line in extra)
            emit({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": note}]}})
            final = f"{last_text}\n\n{note}" if last_text else note
        final = final or "(resposta vazia)"
        self._result(session, emit, final, stopped, guard.steps, denials)
        return TurnResult(final, stopped, guard.steps, session.model)

    async def _run_call(self, session: Session, emit: Emit, rails: guardrails.Guardrails, guard: TurnGuard,
                        host: ToolHost, call: dict, denials: list[str], turn: list[dict]) -> str:
        name, arguments = call["name"], call["arguments"]
        if not isinstance(arguments, dict):
            arguments = {}
        arguments = {k: v for k, v in arguments.items() if k != FILES_KEY}
        if guard.repeated(name, arguments):
            guard.last_repeated = name
            return "loop"
        error, result = await self._execute(session, rails, guard, host, name, arguments, denials, call["id"])
        result = neutralize_context(result if len(result) <= RESULT_CHARS else result[:RESULT_CHARS] + "…")
        emit({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": call["id"], "is_error": error, "content": result}]}})
        turn.append({"role": "tool", "tool_name": name, "tool_call_id": call["id"], "content": result})
        return "error" if error else "ok"

    async def _execute(self, session: Session, rails: guardrails.Guardrails, guard: TurnGuard, host: ToolHost, name: str,
                       arguments: dict, denials: list[str], tool_use_id: str) -> tuple[bool, str]:
        if not guard.allowed(name):
            guard.refuse(name)
            return True, f"a ferramenta {name} não é permitida para este tamanho de modelo"
        if name not in host.specs:
            return True, f"a ferramenta {name} não existe ou não abriu"
        scripted = name == "write_file" and Files(self._roots()).is_script_write(arguments)
        url = arguments.get("url")
        unvouched = name == "web_fetch" and not (isinstance(url, str) and url in host.trusted_urls)
        query = arguments.get("query")
        leaky = name == "web_search" and (session.private or not isinstance(query, str) or len(query) > QUERY_FREE_CHARS)
        leaky = leaky or leaks(name, session, arguments)
        if scripted or unvouched or leaky or guardrails.needs_card(rails, guard.tier, session.mode, name):
            shown = dict(arguments)
            if name == "run_shell":
                try:
                    files = Files(self._roots()).referenced(self.folder, arguments.get("command"))
                except ToolFailure as e:
                    denials.append(name)
                    return True, f"não executei: {e}"
                if files:
                    shown[FILES_KEY] = files
            outcome = await self.approver.ask(name, shown, tool_use_id)
            if outcome != "allow":
                denials.append(name)
                return True, "o usuário negou a ação" if outcome == "deny" else "não executei: ninguém aprovou a tempo"
            if name == "email_send" and host.authorize:
                host.authorize(arguments)
        try:
            result = await host.call(name, arguments)
        except ToolFailure as e:
            return True, str(e)
        except Exception as e:
            return True, f"a ferramenta {name} falhou ({type(e).__name__})"
        if name not in LEAVES_TURN_CLEAN:
            self._mark_private(session)
        return False, result


def record_turn(folder: Path, session: Session, surface: str, text: str, result: TurnResult) -> None:
    path = folder / "conversas" / f"{session.conversation}.jsonl"
    at = transcript.stamp()
    lines = []
    if not path.exists():
        lines.append({"v": transcript.VERSION, "at": at, "kind": "session", "session": session.conversation, "engine": ENGINE, "reason": "new"})
    lines.append({"v": transcript.VERSION, "at": at, "kind": "user", "surface": surface, "text": text})
    if not result.is_error:
        lines.append({"v": transcript.VERSION, "at": at, "kind": "assistant", "surface": surface, "text": result.text,
                      "engine": ENGINE, "model": result.model})
    transcript.append_line(path, "\n".join(transcript.encode(line) for line in lines))
