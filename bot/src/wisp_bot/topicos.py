"""Topico do Telegram = nota no brain. E o que deixa continuar de qualquer maquina.

A sessao do Claude viaja pelo canal ssh (sessao.py, ctl.py), nunca por esta nota:
o jsonl pode ter segredo. A nota carrega o estado e o rastro de onde a sessao esta:

  frontmatter  topic_key, name, cwd (com ~, resolve nas duas maquinas), status
               (active | terminal | encerrado), onde (telegram | terminal-mac |
               terminal-pc). Os session_* NAO sao mais escritos aqui: cada host grava so o
               seu sessoes-<HOST>.json (ponteiro por topico) e meta() resolve entre eles;
               o frontmatter antigo vale so como fallback de migracao
  ## Briefing  a tarefa como nasceu, escrita uma vez
  ## Onde está o agente do topico reescreve ao fim de todo turno com substancia
  ## Log       o bot anexa uma linha por turno — deterministico, nao depende do modelo

Um topico sem sessao local abre uma sessao nova e manda o Claude ler esta nota antes
de responder. So o host ativo escreve, entao nao ha conflito de merge.

A pasta fica fora do protocolo de index do vault (como daily/): sao notas de
estado, geridas pelo bot.
"""
from __future__ import annotations
import asyncio, json, logging, os, re, signal, time
from datetime import datetime
from pathlib import Path

from .config import CURRENT as _CFG

log = logging.getLogger("wisp.topicos")

BRAIN = _CFG.brain
DIR = _CFG.topics_dir
REL = _CFG.topics_rel
PERSONA = _CFG.persona
LOG_GERAL_MAX = 30          # o Geral e continuo: o Log dele e janela, nao historico
TRECHO_MSG, TRECHO_RESP = 280, 400


_FM = re.compile(r"\A---\n(.*?)\n---\n", re.S)


def _slug(nome: str) -> str:
    import unicodedata
    s = unicodedata.normalize("NFKD", nome).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")[:40] or "topico"


def _thread(key: str) -> str:
    return key.rsplit(":", 1)[-1]


def portavel(cwd: str) -> str:
    home = str(Path.home())
    return "~" + cwd[len(home):] if cwd == home or cwd.startswith(home + "/") else cwd


def _ler(p: Path) -> str:
    try:
        return p.read_text("utf-8")
    except OSError:
        return ""


def _fm(texto: str) -> dict:
    m = _FM.match(texto)
    out = {}
    if m:
        for linha in m.group(1).splitlines():
            k, sep, v = linha.partition(":")
            if sep and not linha.startswith((" ", "-")):
                out[k.strip()] = v.strip().strip('"')
    return out


def caminho(key: str) -> Path | None:
    """Acha a nota pelo topic_key (o nome do arquivo carrega o thread, mas o slug
    pode ter mudado)."""
    if not DIR.is_dir():
        return None
    t = _thread(key)
    cands = [DIR / "topico-geral.md"] if t == "0" else sorted(DIR.glob(f"topico-{t}-*.md"))
    for p in cands:
        if p.exists() and _fm(_ler(p)).get("topic_key") == key:
            return p
    return None


def rel(p: Path) -> str:
    return str(p.relative_to(BRAIN))


# ---- ponteiro de sessao: UM arquivo por host, so o dono escreve (como jornal-/vagas-) ----

def arquivo_sessoes(host: str) -> Path:
    return DIR / f"sessoes-{host}.json"


def _ler_sessoes() -> dict[str, dict]:
    """host -> {topic_key: entrada}, de todo sessoes-*.json. Arquivo ausente ou quebrado = vazio."""
    out = {}
    for p in sorted(DIR.glob("sessoes-*.json")) if DIR.is_dir() else []:
        try:
            d = json.loads(p.read_text("utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(d, dict):
            out[p.stem[len("sessoes-"):]] = d
    return out


def _inteiro(v) -> int:
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return 0


def resolver_sessao(key: str, por_host: dict[str, dict]) -> dict | None:
    """Entre os hosts, a entrada de maior session_last; o host e o do arquivo. Devolve os campos
    no formato do frontmatter (strings), ou None se nenhum host tem o topico. Empate: ordem do host."""
    melhor = None
    for host, d in sorted(por_host.items()):
        e = d.get(key) if isinstance(d, dict) else None
        if not isinstance(e, dict) or not e.get("session_id"):
            continue
        if melhor is None or _inteiro(e.get("session_last")) > _inteiro(melhor[1].get("session_last")):
            melhor = (host, e)
    if not melhor:
        return None
    host, e = melhor
    return {"session_id": str(e["session_id"]), "session_host": host,
            "session_started": "false" if e.get("session_started") in (False, "false") else "true",
            "session_born": str(_inteiro(e.get("session_born"))),
            "session_last": str(_inteiro(e.get("session_last"))),
            "session_size": str(_inteiro(e.get("session_size")))}


def gravar_ponteiro(host: str, key: str, session_id: str, started: bool, born: float, last: float,
                    size: int, cwd: str) -> None:
    """Grava a entrada do topico no arquivo DESTE host (atomico: tmp e replace). So le/escreve o proprio."""
    DIR.mkdir(parents=True, exist_ok=True)
    p = arquivo_sessoes(host)
    try:
        d = json.loads(p.read_text("utf-8")) if p.exists() else {}
        if not isinstance(d, dict):
            raise ValueError("nao e objeto")
    except (OSError, ValueError):
        # ilegivel: guarda de lado em vez de sobrescrever os ponteiros dos outros topicos
        if p.exists():
            p.replace(p.with_suffix(".bad"))
        d = {}
    d[key] = {"session_id": session_id, "session_started": bool(started), "session_born": int(born),
              "session_last": int(last), "session_size": int(size), "cwd": portavel(cwd)}
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1, sort_keys=True), "utf-8")
    tmp.replace(p)


def _com_sessao(d: dict, key: str, sessoes: dict[str, dict]) -> dict:
    """Sobrepoe os session_* do ponteiro por host; sem ponteiro, fica o frontmatter antigo."""
    r = resolver_sessao(key, sessoes)
    if r:
        d.update(r)
    return d


def meta(key: str) -> dict | None:
    p = caminho(key)
    if not p:
        return None
    d = _com_sessao(_fm(_ler(p)), key, _ler_sessoes())
    d["_path"] = str(p)
    d["_tem_historia"] = bool(re.search(r"^- \d{4}-\d{2}-\d{2} ", _ler(p), re.M))
    return d


def ultimo_host(key: str) -> str | None:
    """Host da ultima linha do Log ("- data hora · host · ...")."""
    p = caminho(key)
    linhas = re.findall(r"^- \d{4}-\d{2}-\d{2} \d{2}:\d{2} · (\w+) · ", _ler(p) if p else "", re.M)
    return linhas[-1] if linhas else None


def onde_esta_hash(key: str) -> str:
    """sha1 da secao "## Onde está" — o mesmo calculo do hook topico-gate.sh.
    Se mudar aqui, muda la."""
    import hashlib
    p = caminho(key)
    m = re.search(r"^## Onde está\n(.*?)(?=^## |\Z)", _ler(p) if p else "", re.S | re.M)
    return hashlib.sha1((m.group(1).strip() if m else "").encode()).hexdigest()


def garantir(key: str, nome: str, cwd: str, briefing: str = "") -> Path:
    """Cria a nota se nao existe. Nunca sobrescreve uma existente."""
    p = caminho(key)
    if p:
        return p
    DIR.mkdir(parents=True, exist_ok=True)
    t = _thread(key)
    p = DIR / ("topico-geral.md" if t == "0" else f"topico-{t}-{_slug(nome)}.md")
    agora = datetime.now().strftime("%Y-%m-%d %H:%M")
    geral = t == "0"
    corpo = [
        "---",
        f"aliases: [{nome}]",
        "tags: [telegram, topico]",
        "status: active",
        f"created: {agora}",
        f'topic_key: "{key}"',
        f"name: {nome}",
        f"cwd: {portavel(cwd)}",
        "---",
        "",
        f"# {nome}",
        "",
        f"> Estado vivo de um tópico do {PERSONA} no Telegram. Qualquer máquina "
        "continua daqui; a sessão do Claude vai junto pelo `wisp topic`, nunca por esta nota.",
        "",
    ]
    if not geral:
        corpo += ["## Briefing", "", briefing.strip() or "_(aberto sem briefing)_", "",
                  "## Onde está", "", f"_(o {PERSONA} do tópico reescreve esta seção ao fim de cada turno "
                  "com substância: o que está feito, o que está sujo no disco, o próximo passo)_", ""]
    corpo += ["## Log", ""]
    tmp = p.with_suffix(".tmp")
    tmp.write_text("\n".join(corpo), "utf-8")
    tmp.replace(p)
    return p


def _uma_linha(s: str, n: int) -> str:
    s = re.sub(r"<[^>]+>", "", s)                 # a resposta vem em HTML do Telegram
    s = re.sub(r"\s+", " ", s).strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def anexar_log(key: str, host: str, msg: str, resposta: str, ok: bool = True) -> None:
    p = caminho(key)
    if not p:
        return
    texto = _ler(p)
    linha = (f"- {datetime.now():%Y-%m-%d %H:%M} · {host} · **Você:** {_uma_linha(msg, TRECHO_MSG)}"
             f" → {'' if ok else '❌ '}{_uma_linha(resposta, TRECHO_RESP)}")
    if "\n## Log" not in texto:
        texto = texto.rstrip("\n") + "\n\n## Log\n"
    texto = texto.rstrip("\n") + "\n" + linha + "\n"
    if _thread(key) == "0":
        cab, _, corpo = texto.partition("\n## Log\n")
        linhas = [l for l in corpo.splitlines() if l.startswith("- ")][-LOG_GERAL_MAX:]
        texto = cab + "\n## Log\n\n" + "\n".join(linhas) + "\n"
    tmp = p.with_suffix(".tmp")
    tmp.write_text(texto, "utf-8")
    tmp.replace(p)


def _set_fm(key: str, campo: str, valor: str) -> None:
    p = caminho(key)
    if not p:
        return
    texto = _ler(p)
    m = _FM.match(texto)
    if not m:
        return
    fm = m.group(1)
    if re.search(rf"^{campo}:", fm, re.M):
        fm = re.sub(rf"^{campo}:.*$", f"{campo}: {valor}", fm, count=1, flags=re.M)
    else:
        fm += f"\n{campo}: {valor}"
    texto = f"---\n{fm}\n---\n" + texto[m.end():]
    tmp = p.with_suffix(".tmp")
    tmp.write_text(texto, "utf-8")
    tmp.replace(p)


def set_campos(key: str, **campos: str) -> None:
    """Varios campos do frontmatter de uma vez (onde, session_id, session_host...)."""
    for campo, valor in campos.items():
        _set_fm(key, campo, str(valor))


def set_status(key: str, status: str) -> None:
    _set_fm(key, "status", status)


def set_cwd(key: str, cwd: str) -> None:
    _set_fm(key, "cwd", portavel(cwd))


def abertos() -> list[dict]:
    out = []
    sessoes = _ler_sessoes()
    for p in sorted(DIR.glob("topico-*.md")) if DIR.is_dir() else []:
        d = _fm(_ler(p))
        if d.get("status") == "active" and d.get("topic_key"):
            _com_sessao(d, d["topic_key"], sessoes)
            d["_path"] = str(p)
            out.append(d)
    return out


def encerrados() -> list[dict]:
    out = []
    sessoes = _ler_sessoes()
    for p in sorted(DIR.glob("topico-*.md")) if DIR.is_dir() else []:
        d = _fm(_ler(p))
        if d.get("status") == "encerrado" and d.get("topic_key"):
            out.append(_com_sessao(d, d["topic_key"], sessoes))
    return out


# ---- brain-sync: pull antes de ler, push (agrupado) depois de escrever ----

SYNC = _CFG.brain_sync_cmd     # argv; None = sem sync (brain so local): pull/push sao no-op
_push_agendado: asyncio.Task | None = None


async def _sync(verbo: str, timeout: float) -> bool:
    if not SYNC:
        return True
    p = None
    try:
        p = await asyncio.create_subprocess_exec(
            *SYNC, verbo, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            start_new_session=True)
        await asyncio.wait_for(p.wait(), timeout=timeout)
        return p.returncode == 0
    except (OSError, asyncio.TimeoutError) as e:     # FileNotFoundError e PermissionError sao OSError
        log.warning("brain-sync %s falhou: %s", verbo, e)
        return False
    finally:
        if p is not None and p.returncode is None:   # estouro ou cancelamento: nao deixa o grupo vivo
            await _matar_grupo(p)


async def _matar_grupo(p) -> None:
    """SIGTERM no grupo do brain-sync (o git solta o index.lock no TERM), ate 2 s para o lider sair e meio segundo para
    os filhos limparem; depois SIGKILL no grupo para o que sobrou."""
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    try:
        await asyncio.wait_for(asyncio.shield(p.wait()), timeout=2)
        await asyncio.sleep(0.5)
    except (asyncio.TimeoutError, asyncio.CancelledError):
        pass
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


async def pull() -> bool:
    return await _sync("pull", 45)


def push_logo(atraso: float = 1.0) -> None:
    """Agenda um push; varios turnos seguidos viram um push so."""
    global _push_agendado
    if _push_agendado and not _push_agendado.done():
        return

    async def _vai():
        await asyncio.sleep(atraso)
        await _sync("push", 90)
    _push_agendado = asyncio.create_task(_vai())


async def push_agora(timeout: float = 90) -> bool:
    """Push na hora (fim de um job do dia): o outro host nao pode repetir o que este acabou de postar."""
    try:
        return await _sync("push", timeout)
    except Exception as e:                     # quem chama e um loop diario: nunca levanta
        log.warning("push_agora falhou: %s", e)
        return False
