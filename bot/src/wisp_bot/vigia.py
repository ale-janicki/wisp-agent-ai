"""Vigia sob demanda: registro das sessoes do terminal que o usuario pediu para acompanhar + detector.

Puro de proposito (so stdlib, sem `telegram`): a CLI do harness e o python do sistema importam isto.
O detector e o do probe 4 (~/.claude/state/vigia/probe4_stall.py), validado em 273 jsonl reais:
agente cujo ultimo evento e end_turn terminou; agente vivo sem tool_use novo ha 15 min (30 com um Bash
em voo sem resultado) ou com >= 2 injects "cut off mid-stream" esta travado. Le so o fim (64 KB) de cada
jsonl. O slug e o de sessao.slug, reescrito aqui porque sessao importa hosting (e este modulo nao pode
puxar o bot).

vigias.json: {session_id: {session_id, cwd, thread, chat, nome, host, desde, estado, avisado, avisado_fim, motivo}}

O vigia e um espelho persistente: "encerrada" quer dizer so "o turno acabou e nada esta em voo" e se repete a cada
turno (o bot avisa uma vez por `fim`, guardado em avisado_fim). O registro sai apenas quando `remover` vem
verdadeiro: /exit, jsonl parado ha mais de 12h ou jsonl que nunca apareceu (alem do desvincular e do topico morto).
"""
from __future__ import annotations
import contextlib, fcntl, json, os, re, threading
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .config import CURRENT as _CFG

ARQUIVO = Path(os.environ.get("VIGIAS_FILE") or str(_CFG.state_dir / "vigias.json"))
PROJETOS = Path.home() / ".claude" / "projects"

CAUDA = 1024 * 1024                  # 1 MB: uma linha de anexo sozinha passa de 100 KB e engolia a resposta
TRAVADO_MIN = 15
BASH_MIN = 30
CUTOFF_LIMITE = 2
CUTOFF = "cut off mid-stream"
LOCAL_CMD = re.compile(r"<(?:local-command-caveat|command-name|local-command-stdout|local-command-stderr)>")
OCIOSA_S = 120                     # sessao principal parada ha tanto, sem nada em voo = encerrada
IDADE_MAX = timedelta(hours=12)    # agente morto de ontem sem end_turn nao trava a vigia para sempre
SEM_JSONL = timedelta(minutes=30)  # sessao cujo jsonl nunca aparece: erro de id/cwd, nao espera eterna
TEXTO_MAX = 3000
BG_OCIOSO = timedelta(hours=12)    # shell em segundo plano sem aviso de fim ha tanto = esquecido, nao conta em voo
PROPRIO_VIGIA = "vigia-wait"       # o shell em segundo plano do proprio alarme nunca segura o "rodando"
NOTIF = re.compile(r"<tool-use-id>([^<]+)</tool-use-id>")

_lock = threading.Lock()


# ---- registro ----

def ler(arquivo: Path | None = None) -> dict:
    try:
        d = json.loads((arquivo or ARQUIVO).read_text("utf-8"))
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def _gravar(d: dict, arquivo: Path | None) -> None:
    alvo = arquivo or ARQUIVO
    alvo.parent.mkdir(parents=True, exist_ok=True)
    tmp = alvo.with_name(alvo.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(d, indent=2, ensure_ascii=False), "utf-8")
    os.replace(tmp, alvo)                          # troca atomica: leitor nunca ve json pela metade


@contextlib.contextmanager
def _travado(arquivo: Path | None):
    """Exclusao entre threads (_lock) e entre processos (flock num .lock ao lado): o bot e a CLI do harness escrevem."""
    alvo = arquivo or ARQUIVO
    alvo.parent.mkdir(parents=True, exist_ok=True)
    with _lock, open(alvo.with_name(alvo.name + ".lock"), "a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lk, fcntl.LOCK_UN)


def registrar(rec: dict, arquivo: Path | None = None) -> None:
    with _travado(arquivo):
        d = ler(arquivo)
        d[rec["session_id"]] = rec
        _gravar(d, arquivo)


def atualizar(sid: str, arquivo: Path | None = None, **campos) -> None:
    with _travado(arquivo):
        d = ler(arquivo)
        if sid in d and any(d[sid].get(k) != v for k, v in campos.items()):
            d[sid].update(campos)
            _gravar(d, arquivo)


def remover(sid: str, arquivo: Path | None = None) -> None:
    with _travado(arquivo):
        d = ler(arquivo)
        if d.pop(sid, None) is not None:
            _gravar(d, arquivo)


# ---- detector ----

def slug(cwd: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def _ts(s: str | int | float) -> datetime:
    if isinstance(s, (int, float)) and not isinstance(s, bool):
        return datetime.fromtimestamp(s, timezone.utc)
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def _cauda(path: Path) -> list[dict]:
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            tam = f.tell()
            f.seek(max(0, tam - CAUDA))
            bruto = f.read()
    except OSError:
        return []
    linhas = bruto.split(b"\n")
    if tam > CAUDA:
        linhas = linhas[1:]                        # primeira linha vem cortada
    out = []
    for l in linhas:
        try:
            d = json.loads(l)
        except ValueError:
            continue
        if isinstance(d, dict):
            out.append(d)
    return out


def _eventos(linhas: list[dict]) -> list[tuple]:
    """(ts, tipo, nome, id, texto). tipo: tool | result | end | cutoff | prompt."""
    ev = []
    for d in linhas:
        t = d.get("timestamp")
        if not t:
            continue
        try:
            ts = _ts(t)
        except (ValueError, TypeError, AttributeError, OverflowError, OSError):
            continue
        msg = d.get("message") or {}
        c = msg.get("content")
        if d.get("type") == "assistant" and isinstance(c, list):
            texto = "\n".join(b.get("text", "") for b in c if b.get("type") == "text").strip()
            for b in c:
                if b.get("type") == "tool_use":
                    ev.append((ts, "tool", b.get("name"), b.get("id"), ""))
            if texto:
                ev.append((ts, "texto", None, None, texto))
            if msg.get("stop_reason") == "end_turn":
                ev.append((ts, "end", None, None, ""))
        elif d.get("type") == "user" and isinstance(c, str) and LOCAL_CMD.search(c):
            if "<command-name>/exit</command-name>" in c:   # /exit: a sessao fechou no terminal
                ev.append((ts, "exit", None, None, ""))
            # outros comandos locais (/model, /clear, eco deles) nao sao turno do modelo
        elif d.get("type") == "user":
            resultado = False
            if isinstance(c, list):
                for b in c:
                    if b.get("type") == "tool_result":
                        resultado = True
                        ev.append((ts, "result", None, b.get("tool_use_id"), ""))
            if CUTOFF in json.dumps(c):
                ev.append((ts, "cutoff", None, None, ""))
            elif not resultado:
                ev.append((ts, "prompt", None, None, ""))
    return sorted(ev, key=lambda e: e[0])


def _texto_notificacao(d: dict) -> str:
    """Texto de um aviso de fim de tarefa em segundo plano, ou "". Ele aparece como mensagem user (string) e,
    quando chega no meio de um turno, como registro queue-operation com `content`. Resultado de tool que apenas
    cita um aviso (tool_result) nao conta."""
    if d.get("type") == "queue-operation":
        c = d.get("content")
    elif d.get("type") == "user":
        c = (d.get("message") or {}).get("content")
        if isinstance(c, list):
            c = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    else:
        return ""
    return c if isinstance(c, str) and c.lstrip().startswith("<task-notification>") else ""


def _bg_pendentes(linhas: list[dict], agora: datetime) -> list[str]:
    """Ids de Bash com run_in_background cujo aviso de fim ainda nao chegou. Fora: o vigia-wait do proprio vigia
    e shell iniciado ha mais de BG_OCIOSO."""
    abertos: dict[str, datetime] = {}
    for d in linhas:
        try:
            ts = _ts(d["timestamp"])
        except (KeyError, ValueError, TypeError, AttributeError, OverflowError, OSError):
            continue
        if ts > agora:
            continue
        c = (d.get("message") or {}).get("content")
        if d.get("type") == "assistant" and isinstance(c, list):
            for b in c:
                inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                if (b.get("type") == "tool_use" and b.get("name") == "Bash" and inp.get("run_in_background")
                        and PROPRIO_VIGIA not in str(inp.get("command", ""))):
                    abertos[b.get("id")] = ts
        elif (n := _texto_notificacao(d)):
            for i in NOTIF.findall(n):
                abertos.pop(i, None)
    return [i for i, ts in abertos.items() if agora - ts <= BG_OCIOSO]


def _agente(ev: list[tuple], agora: datetime) -> tuple[bool, str]:
    """(travado, motivo) de um subagente ja filtrado por `agora`. Fim de turno nao e travado."""
    visto = [e for e in ev if e[0] <= agora and e[1] != "prompt" and e[1] != "texto"]
    if not visto or visto[-1][1] == "end":
        return False, ""
    tools = [e for e in visto if e[1] == "tool"]
    feitos = {e[3] for e in visto if e[1] == "result"}
    cortes = sum(1 for e in visto if e[1] == "cutoff")
    ultima = tools[-1] if tools else None
    if cortes >= CUTOFF_LIMITE:
        return True, f"cortado no meio da resposta x{cortes}"
    if ultima is None:
        return False, ""
    base = max(ultima[0], visto[-1][0] if visto[-1][1] == "cutoff" else ultima[0])
    idle = (agora - base).total_seconds() / 60
    limite = BASH_MIN if ultima[2] == "Bash" and ultima[3] not in feitos else TRAVADO_MIN
    if idle >= limite:
        return True, f"{idle:.0f} min sem tool (limite {limite})"
    return False, ""


_FECHADOS = re.compile(r'"name":\s*"TaskStop",\s*"input":\s*\{\s*"task_id":\s*"([A-Za-z0-9_-]+)"|<task-id>([A-Za-z0-9_-]+)</task-id>')
_fechados_cache: dict[str, tuple[int, dict[str, datetime]]] = {}


def _agentes_fechados(principal: Path) -> dict[str, datetime]:
    """{id do subagente: quando o jsonl principal o deu por encerrado (TaskStop ou <task-notification>)}.
    O arquivo do subagente morto nunca ganha end_turn, entao so o principal sabe. Vale o ultimo fechamento:
    um agente retomado por SendMessage volta a rodar depois dele. Le o arquivo inteiro (o TaskStop pode estar
    antes da cauda) e guarda pelo tamanho, para nao reler a cada minuto."""
    try:
        tam = principal.stat().st_size
    except OSError:
        return {}
    c = _fechados_cache.get(str(principal))
    if c and c[0] == tam:
        return c[1]
    ids: dict[str, datetime] = {}
    try:
        with principal.open("r", encoding="utf-8", errors="replace") as fh:
            for linha in fh:
                achados = _FECHADOS.findall(linha)
                if not achados:
                    continue
                try:
                    ts = _ts(json.loads(linha).get("timestamp"))
                except (ValueError, TypeError, AttributeError, OverflowError, OSError):
                    continue
                for a, b in achados:
                    k = a or b
                    if k not in ids or ts > ids[k]:
                        ids[k] = ts
    except OSError:
        return {}
    _fechados_cache[str(principal)] = (tam, ids)
    return ids


def _jsonl_principal(sid: str, cwd: str) -> Path | None:
    p = PROJETOS / slug(cwd) / f"{sid}.jsonl"
    if p.is_file():
        return p
    copias = sorted(PROJETOS.glob(f"*/{sid}.jsonl"))        # o cwd pode ter mudado de caminho
    return max(copias, key=lambda c: c.stat().st_size) if copias else None


def avaliar(sid: str, cwd: str, agora: datetime | None = None, desde: str | int | float | None = None) -> dict:
    """{"estado": rodando|travado|encerrada, "motivo": str, "ultimo_texto": str} (+ "fim": iso do ultimo end_turn e
    "remover": True quando o espelho deve sair do registro, em "encerrada"). Sem LLM, so disco.
    `desde` (iso do registro) so serve para desistir de um jsonl que nunca resolve."""
    agora = agora or datetime.now(timezone.utc)
    principal = _jsonl_principal(sid, cwd)
    if principal is None:
        try:
            velho = desde is not None and agora - _ts(desde) > SEM_JSONL
        except (ValueError, TypeError, AttributeError, OverflowError, OSError):
            velho = False
        if velho:
            return {"estado": "encerrada", "motivo": "jsonl da sessao nao apareceu em 30 min", "ultimo_texto": "",
                    "fim": "", "remover": True}
        return {"estado": "rodando", "motivo": "jsonl da sessao nao achado", "ultimo_texto": ""}

    vivos = 0
    mortos = _agentes_fechados(principal)
    for arq in sorted((principal.parent / sid / "subagents").glob("agent-*.jsonl")):
        ev = _eventos(_cauda(arq))
        ev = [e for e in ev if e[0] <= agora]
        reais = [e for e in ev if e[1] not in ("prompt", "texto")]
        fechou = mortos.get(arq.stem[6:])
        if fechou and reais and fechou >= reais[-1][0]:    # TaskStop/aviso de fim depois do ultimo passo: morto
            continue
        if not reais or reais[-1][1] == "end" or agora - reais[-1][0] > IDADE_MAX:
            continue
        travado, motivo = _agente(ev, agora)
        if travado:
            return {"estado": "travado", "motivo": f"{arq.stem[6:14]}: {motivo}",
                    "ultimo_texto": _ultimo_texto(principal, agora)}
        vivos += 1

    linhas = _cauda(principal)
    ev = [e for e in _eventos(linhas) if e[0] <= agora]
    ativos = [e for e in ev if e[1] != "texto"]
    texto = next((e[4] for e in reversed(ev) if e[1] == "texto"), "")[:TEXTO_MAX]
    fim = next((e[0].isoformat() for e in reversed(ativos) if e[1] == "end"), "")
    if vivos:
        return {"estado": "rodando", "motivo": f"{vivos} agente(s) vivo(s)", "ultimo_texto": texto}
    if ativos and ativos[-1][1] == "exit":
        return {"estado": "encerrada", "motivo": "sessao fechada no terminal", "ultimo_texto": texto,
                "fim": fim, "remover": True}
    if ev and agora - ev[-1][0] > IDADE_MAX:
        return {"estado": "encerrada", "motivo": "sessao parada ha mais de 12h", "ultimo_texto": texto,
                "fim": fim, "remover": True}
    if ativos and ativos[-1][1] == "end":
        bg = _bg_pendentes(linhas, agora)
        if bg:
            return {"estado": "rodando", "motivo": f"{len(bg)} shell(s) em segundo plano", "ultimo_texto": texto}
        parado = (agora - ativos[-1][0]).total_seconds()
        if parado >= OCIOSA_S:
            return {"estado": "encerrada", "motivo": "turno terminou, nada em voo", "ultimo_texto": texto,
                    "fim": fim}
        return {"estado": "rodando", "motivo": "turno acabou de terminar", "ultimo_texto": texto}
    return {"estado": "rodando", "motivo": "turno em andamento", "ultimo_texto": texto}


def fim_a_avisar(av: dict, rec: dict) -> bool:
    """True se `av` traz um fim de turno ainda nao avisado e posterior ao vinculo (`desde`): um turno que ja
    tinha acabado antes de o usuario pedir o espelho nao gera "terminou"."""
    fim = av.get("fim")
    if not fim or fim == rec.get("avisado_fim"):
        return False
    try:
        return rec.get("desde") is None or _ts(fim) > _ts(rec["desde"])
    except (ValueError, TypeError, AttributeError, OverflowError, OSError):
        return True


def _pergunta_pendente(principal: Path) -> dict | None:
    """{"id", "texto"} do ultimo AskUserQuestion do jsonl principal ainda sem resposta, senao None."""
    linhas = _cauda(principal)
    pend, respondidos = None, set()
    for d in linhas:
        c = (d.get("message") or {}).get("content")
        if not isinstance(c, list):
            continue
        for b in c:
            if b.get("type") == "tool_use" and b.get("name") == "AskUserQuestion":
                qs = (b.get("input") or {}).get("questions") or []
                partes = []
                for q in qs:
                    ops = " · ".join(o.get("label", "") for o in (q.get("options") or []))
                    partes.append(f"{q.get('question', '')}\n  {ops}" if ops else q.get("question", ""))
                pend = {"id": b.get("id"), "texto": "\n".join(partes)[:TEXTO_MAX]}
            elif b.get("type") == "tool_result":
                respondidos.add(b.get("tool_use_id"))
    return pend if pend and pend["id"] not in respondidos else None


def _ultimo_texto(principal: Path, agora: datetime) -> str:
    ev = [e for e in _eventos(_cauda(principal)) if e[0] <= agora and e[1] == "texto"]
    return ev[-1][4][:TEXTO_MAX] if ev else ""


# ---- modo celular (/me-avisa): o Telegram responde no lugar do terminal ----

PERGUNTA_TERMINAL = "essa pergunta só responde no terminal; as próximas vêm por aqui"
JANELA_ESCRITA_S = 60              # outro processo escreveu no jsonl ha menos que isto = o terminal esta rodando
MODOS_CELULAR = ("celular", "adotada")   # adotada = o topico ja e dono; o guard segue ativo se o terminal voltar a rodar
MARCAS = Path(os.environ.get("CELULAR_DIR") or str(_CFG.state_dir / "celular"))   # a marca vale 10 min (hook)
TERMINAL_PARADO = timedelta(minutes=TRAVADO_MIN)   # sem end_turn mas sem escrita ha tanto = terminal morto, nao espera eterna


def modo_celular(sid: str, arquivo: Path | None = None) -> bool:
    """True se a sessao tem registro de vigia com modo=celular (o hook de AskUserQuestion consulta isto)."""
    return (ler(arquivo).get(sid) or {}).get("modo") in MODOS_CELULAR


def marcar_celular(sid: str) -> None:
    """Marca sincrona de "vou vincular esta sessao ao celular": bloqueia o AskUserQuestion antes de o topico existir."""
    MARCAS.mkdir(parents=True, exist_ok=True)
    (MARCAS / sid).write_text(str(int(datetime.now(timezone.utc).timestamp())), "utf-8")


def soltar_marca(sid: str) -> None:
    with contextlib.suppress(OSError):
        (MARCAS / sid).unlink()


def abertura_celular(sid: str, cwd: str, agora: datetime | None = None) -> tuple[str, str | None]:
    """(texto HTML, id da pergunta aberta) para o 1o post do modo celular: o que roda, o ultimo texto do assistant
    e a pergunta que ja estava aberta no terminal (essa nao tem como ser respondida daqui)."""
    from html import escape
    av = avaliar(sid, cwd, agora)
    partes = ["📱 modo celular ligado. " + ("O que está rodando: " + av["motivo"] if av["estado"] != "encerrada"
                                           else "Nada em andamento agora.")]
    if av.get("ultimo_texto"):
        partes.append(f"Última resposta:\n<pre>{escape(av['ultimo_texto'])}</pre>")
    principal = _jsonl_principal(sid, cwd)
    perg = _pergunta_pendente(principal) if principal else None
    if perg:
        partes.append(f"❓ esperando você no terminal:\n{escape(perg['texto'])}\n<i>{PERGUNTA_TERMINAL}</i>")
    return "\n\n".join(partes), perg["id"] if perg else None


def terminal_ativo(sid: str, cwd: str, agora: datetime | None = None, escrita_bot: float = 0.0) -> bool:
    """True se um processo que nao e o bot esta no meio de um turno desta sessao: o ultimo evento do jsonl principal
    nao e end_turn/exit (e a escrita e recente), ou algo foi anexado ha menos de JANELA_ESCRITA_S sem ter sido o bot
    (`escrita_bot` = epoch da ultima escrita do proprio bot). Sem jsonl: livre."""
    agora = agora or datetime.now(timezone.utc)
    principal = _jsonl_principal(sid, cwd)
    if principal is None:
        return False
    try:
        mtime = datetime.fromtimestamp(principal.stat().st_mtime, timezone.utc)
    except OSError:
        return False
    ativos = [e for e in _eventos(_cauda(principal)) if e[1] != "texto"]
    meio_de_turno = bool(ativos) and ativos[-1][1] not in ("end", "exit")
    do_bot = bool(escrita_bot) and mtime.timestamp() <= escrita_bot + 2
    if meio_de_turno:                              # turno do bot interrompido (/stop, timeout, restart) deixa o jsonl assim
        return agora - mtime < TERMINAL_PARADO and not do_bot
    return (agora - mtime).total_seconds() < JANELA_ESCRITA_S and not do_bot
