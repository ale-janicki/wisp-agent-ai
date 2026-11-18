"""Invoca o Claude Code sem bloquear o loop do bot.

O turno do Geral precisa ser curto: por isso tudo aqui e asyncio e o processo
roda solto. Nada neste modulo pode usar subprocess sincrono.
"""
from __future__ import annotations
import asyncio, json, os, re, shutil
from dataclasses import dataclass
from typing import Awaitable, Callable

from . import hosting
from .config import CURRENT as _CFG, config_path
from .hosting import HOST

# O Claude escreve markdown; o Telegram nao renderiza markdown. Sem esta instrucao
# a resposta chega com ** e ## crus na tela.
TELEGRAM_STYLE = """You are answering through Telegram. Format rules, they are hard:
- Allowed tags ONLY: <b> <i> <u> <s> <code> <pre> <a href="">. Nothing else.
- NEVER use markdown: no **bold**, no ##heading, no ---, no | tables |, no ``` fences.
  Use <pre> for code blocks and <code> for inline code.
- Escape &, < and > as &amp; &lt; &gt; when they are literal text.
- Be short: aim for 8-12 lines. Offer detail instead of dumping it.
- No running commentary ("now I'll run X..."): only the final answer reaches the user.
- A pending question is asked once; do not repeat it in every later message.
Keep every other convention from CLAUDE.md. If it asks for a STATUS block, emit it
normally and do not mention it: the bot strips it before sending.
"""


CLAUDE_BIN = _CFG.claude_bin     # o caminho que o setup gravou no wisp.json; vence o PATH

# agent.permissionMode do profile.json (o mesmo que o app grava). O Telegram ainda nao mostra
# pedidos de aprovacao: "default" (pedir) vira "auto". Sem valor, o bot segue sem pedir, como sempre.
PERMISSAO_PADRAO = "bypassPermissions"
_PERMISSAO_NO_BOT = {"default": "auto", "manual": "auto", "auto": "auto", "bypassPermissions": "bypassPermissions"}


def permission_mode() -> str:
    """Lido a cada turno, para uma troca no app valer sem reiniciar o bot; perfil ilegivel = padrao."""
    perfil = config_path().parent / "profile.json"
    try:
        agente = json.loads(perfil.read_text("utf-8")).get("agent")
        modo = agente.get("permissionMode") if isinstance(agente, dict) else None
    except (OSError, ValueError, AttributeError):
        modo = None
    return _PERMISSAO_NO_BOT.get(modo, PERMISSAO_PADRAO) if isinstance(modo, str) else PERMISSAO_PADRAO


def claude_bin() -> str:
    """Resolve o binario. Servico launchd/systemd nao herda PATH de shell de login, entao
    depender do PATH aqui e o caminho certo para um FileNotFoundError silencioso."""
    if CLAUDE_BIN and os.path.isfile(os.path.expanduser(CLAUDE_BIN)):
        return os.path.expanduser(CLAUDE_BIN)
    found = shutil.which("claude")
    if found:
        return found
    fallback = os.path.expanduser("~/.local/bin/claude")
    return fallback if os.path.isfile(fallback) else "claude"


CHAVE_OAUTH = "claude-oauth-expirado"
_AUTH = ("oauth session expired", "failed to authenticate", "not logged in", "please run /login")
_alerta_aberto = False      # add ja disparado neste processo, resolve pendente
_resolvido_boot = False     # 1o sucesso do processo ja tentou fechar alerta de antes do restart
_soltas: set[asyncio.Task] = set()


def falha_de_auth(*textos: str) -> bool:
    t = " ".join(textos).lower()
    return any(m in t for m in _AUTH)


async def _alerta(*args: str) -> bool:
    """O mesmo alert_cmd do hosting; sem ele, no-op."""
    return await hosting.rodar_alerta(*args)


def _solta(coro) -> None:
    t = asyncio.ensure_future(coro)
    _soltas.add(t)
    t.add_done_callback(_soltas.discard)


def alertar_oauth() -> None:
    """Login do CLI expirou: todo job do bot falha em silencio. Um add por processo; o
    alert_cmd tambem nao deve repetir chave aberta de mesmo nivel."""
    global _alerta_aberto
    if _alerta_aberto:
        return
    _alerta_aberto = True

    async def add() -> None:
        global _alerta_aberto
        ok = await _alerta("add", "--nivel", "red", "--chave", CHAVE_OAUTH, "--frente", "bot",
                           f"Login do Claude CLI expirou no host {HOST}: todo job do bot (Geral, topicos) "
                           "esta falhando. Conserto: rodar `claude` e `/login` nessa maquina.")
        if not ok:
            _alerta_aberto = False        # nao chegou: a proxima falha tenta de novo
    _solta(add())


def fechar_oauth() -> None:
    """1o sucesso apos alerta aberto, ou 1o sucesso do processo (alerta de antes do restart)."""
    global _alerta_aberto, _resolvido_boot
    if _resolvido_boot and not _alerta_aberto:
        return
    _alerta_aberto = False
    _resolvido_boot = True
    _solta(_alerta("resolve", CHAVE_OAUTH))


@dataclass
class Result:
    ok: bool
    text: str
    session_id: str | None = None
    cost_usd: float | None = None


LIMITE_LINHA = 32 * 1024 * 1024   # linha de tool_result passa fácil de 64KB (default do StreamReader)


def rotulo(item: dict) -> str:
    """Rotulo geral do que o Claude esta fazendo, a partir de um bloco tool_use.
    Pedido de 14/10: resumo amplo ("acessando a pasta x", "validando"), nunca o comando cru."""
    nome = item.get("name") or ""
    i = item.get("input") or {}
    base = lambda p: os.path.basename(str(p or "").rstrip("/"))
    if nome in ("Agent", "Task"):
        tipo = i.get("subagent_type") or ""
        t = {"operator": "fazendo a mudança", "reviewer": "validando as mudanças",
             "reader": "lendo o projeto", "Explore": "lendo o projeto"}.get(tipo, "delegando uma parte")
    elif nome == "Bash":
        cmd = str(i.get("command") or "")
        pasta = re.search(r"(?:cd|-C)\s+([^\s;&|]+)", cmd)
        if re.search(r"pytest|py_compile|\btest|npm (run )?test|tsc|lint", cmd):
            t = "testando"
        elif re.search(r"\bgit\b", cmd):
            t = "conferindo o git"
        elif re.search(r"launchctl|kickstart|systemctl|restart", cmd):
            t = "reiniciando serviço"
        elif re.search(r"curl|ssh|ping|tailscale", cmd, re.I):
            t = "testando conexão"
        elif pasta:
            t = f"acessando a pasta {base(pasta.group(1))}"
        else:
            t = "rodando um comando"
    elif nome == "Read":
        t = f"lendo {base(i.get('file_path'))}"
    elif nome in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        t = f"editando {base(i.get('file_path'))}"
    elif nome in ("Grep", "Glob"):
        t = "buscando no código"
    elif nome in ("WebSearch", "WebFetch"):
        t = "pesquisando na web"
    elif nome == "Skill":
        t = f"usando {i.get('skill') or 'uma skill'}"
    else:
        t = "trabalhando"
    return " ".join(t.split())[:80]


async def run(prompt: str, *, session_id: str, cwd: str, started: bool,
              model: str | None = None, timeout: int = 900,
              extra_prompt: str = "", disallowed: str = "",
              env: dict | None = None, no_tools: bool = False,
              on_event: Callable[[str], None] | None = None,
              on_text: Callable[[str], Awaitable[None] | None] | None = None) -> Result:
    """Um turno. `started` decide entre criar a sessao e retomar. `on_event`
    recebe um rotulo curto a cada tool_use (cosmetico: erro nele e ignorado).
    `on_text` recebe cada bloco de texto do assistant assim que chega; se for
    async, roda como task e o turno so retorna depois de todas terminarem."""
    cmd = [claude_bin(), "--print", "--output-format", "stream-json", "--verbose",
           "--permission-mode", permission_mode(),
           "--append-system-prompt", TELEGRAM_STYLE + extra_prompt]
    cmd += ["--resume", session_id] if started else ["--session-id", session_id]
    if model:
        cmd += ["--model", model]
    if disallowed:
        cmd += ["--disallowedTools", disallowed]
    if no_tools:                  # entrada nao confiavel: sem ferramentas nem MCP
        cmd += ["--tools", "", "--strict-mcp-config"]

    cwd = os.path.expanduser(cwd)  # topics.json pode guardar "~/..." (vincular): sem expandir, isdir falha
    if not os.path.isdir(cwd):
        return Result(False, f"cwd nao existe: {cwd}")

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, cwd=cwd, stdin=asyncio.subprocess.PIPE,
            env={**os.environ, "WISP_SKIP_PULL": "1", **(env or {})}, limit=LIMITE_LINHA,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    except FileNotFoundError:
        return Result(False, f"binario do claude nao encontrado: {claude_bin()}")

    parciais: list[str] = []      # texto do assistant + linhas nao-JSON, p/ fallback
    final: dict | None = None
    tarefas: list[asyncio.Task] = []   # envios de on_text em voo

    def emitir_texto(texto: str) -> None:
        if not on_text:
            return
        try:
            r = on_text(texto)
            if asyncio.iscoroutine(r) or isinstance(r, asyncio.Future):
                tarefas.append(asyncio.ensure_future(r))
        except Exception:
            pass                                  # cosmetico: nunca quebra o turno

    async def esperar_textos() -> None:
        # os parciais saem antes da resposta final: a ordem importa
        if tarefas:
            await asyncio.gather(*tarefas, return_exceptions=True)

    async def ler_stdout() -> None:
        nonlocal final
        async for bruta in proc.stdout:
            linha = bruta.decode("utf-8", "replace").strip()
            if not linha:
                continue
            try:
                ev = json.loads(linha)
            except json.JSONDecodeError:
                parciais.append(linha)
                continue
            if not isinstance(ev, dict):
                parciais.append(linha)
                continue
            if ev.get("type") == "result":
                final = ev
            elif ev.get("type") == "assistant":
                content = (ev.get("message") or {}).get("content")
                for item in content if isinstance(content, list) else []:
                    if not isinstance(item, dict):
                        continue
                    if item.get("type") == "text" and item.get("text"):
                        parciais.append(str(item["text"]))
                        emitir_texto(str(item["text"]))
                    elif item.get("type") == "tool_use" and on_event:
                        try:
                            on_event(rotulo(item))
                        except Exception:
                            pass                  # cosmetico: nunca quebra o turno

    async def tudo() -> bytes:
        proc.stdin.write(prompt.encode("utf-8"))
        try:
            await proc.stdin.drain()
            proc.stdin.close()
        except (BrokenPipeError, ConnectionResetError):
            pass
        # stderr drenado junto com stdout: pipe cheio travaria o processo
        _, err_b, _ = await asyncio.gather(ler_stdout(), proc.stderr.read(), proc.wait())
        return err_b

    async def matar() -> None:
        proc.kill()
        try:
            await asyncio.wait_for(proc.wait(), 5)   # colhe o processo, sem zumbi
        except Exception:
            pass

    try:
        err = await asyncio.wait_for(tudo(), timeout=timeout)
    except asyncio.TimeoutError:
        await matar()
        await esperar_textos()
        return Result(False, f"estourou {timeout}s e foi morto")
    except Exception as e:
        # linha acima do limite etc: sem isso o processo ficaria solto
        await matar()
        await esperar_textos()
        return Result(False, f"leitura do claude falhou: {type(e).__name__}: {e}")

    await esperar_textos()
    if proc.returncode != 0:
        if falha_de_auth((err or b"").decode("utf-8", "replace"), "\n".join(parciais),
                         str((final or {}).get("result") or "")):
            alertar_oauth()
        tail = (err or b"").decode("utf-8", "replace").strip()[-600:]
        motivo = strip_status((final or {}).get("result") or "")
        if "went to sleep" in motivo:
            motivo = "o Mac dormiu no meio da resposta"
        partes = [f"claude saiu com {proc.returncode}", motivo, tail]
        return Result(False, "\n".join(x for x in partes if x))
    fechar_oauth()

    if final is None:
        # sem linha result o texto parcial ainda e util: melhor entregar que engolir
        return Result(True, "\n".join(parciais)[-3500:] or "(resposta vazia)")

    return Result(
        ok=not final.get("is_error", False),
        text=strip_status(final.get("result") or "") or "(resposta vazia)",
        session_id=final.get("session_id"),
        cost_usd=final.get("total_cost_usd"),
    )


# O CLAUDE.md obriga o bloco STATUS em toda resposta, e a regra vence o
# --append-system-prompt: medido em 28/09, ele veio mesmo com instrucao contraria.
# No Telegram o bloco e ruido, entao removo aqui em vez de torcer pelo prompt.
_STATUS = re.compile(r"\n*(?:```[a-z]*\n)?STATUS\s*[·.].*\Z", re.S | re.I)


def strip_status(text: str) -> str:
    return _STATUS.sub("", text).strip()
