"""wisp topic: a topic is one thing, on Telegram and in the terminal.

  listar [--json]             topics on Telegram now (brain notes with status active plus the reader's topics.json),
                              Geral and the system topics included with fixed: true
  status --json               {up, host, state, age_s, reader, claim}
  novo [--cwd D] -- <nome>    empty topic; prints {thread, session_id, cwd, name}
  falar [--origem N] [--anexo F]... -- <thread> <texto>
                              posts the text in an existing topic and its agent answers
  encerrar <thread>           closes the topic
  assumir [--thread N] [--json] [--timeout S]
                              this host is about to send: makes its bot the reader (pair only)
  puxar <thread|nome>         brings the topic to this terminal (pair only)

Everything goes through the bot (queue under its state dir): this CLI never talks to Telegram.
The ssh paths run only when hosting is "pair".
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

from wisp_bot import ctl, hosting, sessao, store, tg_html, topicos
from wisp_bot.config import BotConfig, load_settings

PRAZO_PC_S = 4.0
ASSUMIR_S = 60.0
CLAIM_SSH_S = 6.0
FALAR_S = 30.0
NOVO_S = 15.0
ENCERRAR_S = 300.0
SOLTAR_S = 120.0
SEM_BOT_NO_PC = "nenhum host le o Telegram agora (rode: wisp topic listar)"
_MARCA_TOPICOS = "WISP_TOPICOS "
_LOG = re.compile(r"^- (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) · ", re.M)
_WRAPPERS = ("<command-name>", "<local-command", "<system-reminder>", "<task-notification>")
_MARCA_BOT = "Mensagem do usuario:\n"
_STATUS = ("STATUS ·", "Teu:", "Workers:")
RETOMADA = ("Voltei do Telegram para o terminal. Em 2-4 linhas, em texto de terminal: onde paramos, "
            "o que ficou pendente e o proximo passo. O topico ja esta aqui; ignore instrucoes antigas de puxa-lo.")
SO_UMA_MAQUINA = "a sessão já está nesta máquina: no modo solo não há outra de onde puxar"


def cfg() -> BotConfig:
    return load_settings()


def erro(msg: str, rc: int = 1) -> int:
    print(msg, file=sys.stderr)
    return rc


def pair() -> bool:
    return hosting.MODO == "pair"


# ---- the contract: one function per JSON the app decodes ----

def status_json(estado: dict) -> str:
    return json.dumps(estado, ensure_ascii=False)


def listar_json(lista: list[dict]) -> str:
    return json.dumps(lista, ensure_ascii=False)


def novo_json(thread, session_id: str, cwd: str, name: str) -> str:
    return json.dumps({"thread": thread, "session_id": session_id, "cwd": cwd, "name": name}, ensure_ascii=False)


def claim_json(d: dict) -> str:
    return json.dumps(d, ensure_ascii=False)


# ---- brain ----

def pull_vault() -> None:
    """A topic opened on the other machine may not have arrived: pull the brain before reading its notes."""
    if not topicos.SYNC:
        return
    env = {k: v for k, v in os.environ.items() if k != "WISP_SKIP_PULL"}
    try:
        subprocess.run([*topicos.SYNC, "pull"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=30, start_new_session=True)
    except (OSError, subprocess.SubprocessError):
        pass


def notas(com_geral: bool = False) -> list[dict]:
    """Topic notes with status active or terminal (Geral only with com_geral)."""
    out = []
    sessoes = topicos._ler_sessoes()
    for p in sorted(topicos.DIR.glob("topico-*.md")) if topicos.DIR.is_dir() else []:
        texto = topicos._ler(p)
        d = topicos._fm(texto)
        if d.get("topic_key"):
            d = topicos._com_sessao(d, d["topic_key"], sessoes)
        if d.get("status") not in ("active", "terminal") or not d.get("topic_key"):
            continue
        thread = d["topic_key"].rsplit(":", 1)[-1]
        if thread == "0" and not com_geral:
            continue
        logs = _LOG.findall(texto)
        d.update(thread=thread, ultimo=logs[-1] if logs else "-", turnos=len(logs),
                 onde=d.get("onde") or ("telegram" if d["status"] == "active" else "terminal"))
        out.append(d)
    return out


def status_das_notas() -> dict[int, str]:
    out = {}
    for p in sorted(topicos.DIR.glob("topico-*.md")) if topicos.DIR.is_dir() else []:
        d = topicos._fm(topicos._ler(p))
        chave = str(d.get("topic_key") or "")
        if chave.rsplit(":", 1)[-1].isdigit():
            out[int(chave.rsplit(":", 1)[-1])] = str(d.get("status") or "")
    return out


# ---- who reads Telegram ----

def _local_le() -> tuple[dict, int | None, bool]:
    """(host-state of this host, age in s, this host's bot reads Telegram now and is fresh)."""
    st = hosting.ler_estado_local()
    idade = int(time.time()) - int(st.get("ts", 0)) if st else None
    vivo = bool(st) and idade is not None and idade <= ctl.FRESCO_S
    return st, idade, vivo and st.get("state") == "active"


def ler_pc(prazo: float = PRAZO_PC_S) -> tuple[str | None, str, dict | None]:
    """One ssh to the other machine: (its bot state, its HOME, its topics.json). Unreadable = (None, "", None).
    On timeout the whole process group is killed."""
    argv = hosting.pc_argv()
    if argv is None:
        return None, "", None
    script = (f'cat "{hosting.DIR_REMOTO}/host-state.json" 2>/dev/null; echo; date +%s\n'
              f'echo "{_MARCA_TOPICOS}$HOME"\n'
              f'cat "{hosting.DIR_REMOTO}/topics.json" 2>/dev/null || true\n')
    try:
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             start_new_session=True)
    except OSError:
        return None, "", None
    try:
        out, _ = p.communicate(script.encode(), timeout=prazo)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return None, "", None
    estado_txt, sep, resto = out.decode("utf-8", "replace").partition("\n" + _MARCA_TOPICOS)
    if p.returncode != 0 or not sep:
        return None, "", None
    home_pc, _, corpo = resto.partition("\n")
    try:
        brutos = json.loads(corpo) if corpo.strip() else {}
    except json.JSONDecodeError:
        brutos = None
    return hosting.interpretar_estado_pc(0, estado_txt), home_pc.strip(), brutos if isinstance(brutos, dict) else None


def _do_store() -> dict[int, dict]:
    return {int(t.key.rsplit(":", 1)[-1]): {"name": t.name, "session_id": t.session_id,
                                            "cwd": os.path.expanduser(t.cwd), "started": t.started,
                                            "turns": t.turns, "last_used": t.last_used, "meta": t.meta}
            for t in store.Store(store.STORE).all()}


def _do_pc(brutos: dict, home_pc: str) -> dict[int, dict]:
    out = {}
    for key, t in brutos.items():
        fim = str(key).rsplit(":", 1)[-1]
        if not isinstance(t, dict) or not fim.lstrip("-").isdigit():
            continue
        cwd_pc = str(t.get("cwd") or "")
        out[int(fim)] = {"name": str(t.get("name") or ""), "session_id": str(t.get("session_id") or ""),
                         "cwd": sessao.cwd_espelho(cwd_pc, home_pc, str(Path.home()), os.path.isdir, "", "")
                         if home_pc else "",
                         "started": bool(t.get("started")), "turns": int(t.get("turns") or 0),
                         "last_used": t.get("last_used"), "meta": t.get("meta") if isinstance(t.get("meta"), dict) else {}}
    return out


def _mac_le_visto_do_pc() -> bool:
    mtime, st = hosting.ler_mac_visto()
    return st == "active" and mtime is not None and time.time() - mtime <= hosting.FRESCO_S


def leitura(com_topicos: bool) -> tuple[str | None, dict[int, dict] | None]:
    """(who reads Telegram now: a host name or None, that bot's topics by thread). Topics None = the other
    machine reads and its topics.json did not come over ssh."""
    _, _, le = _local_le()
    if le:
        return hosting.HOST, _do_store() if com_topicos else {}
    if not pair():
        return None, _do_store() if com_topicos else {}
    if hosting.HOST != "mac":
        return ("mac" if _mac_le_visto_do_pc() else None), _do_store() if com_topicos else {}
    pc, home_pc, brutos = ler_pc()
    if pc == "active":
        return "pc", (_do_pc(brutos, home_pc) if brutos is not None else None) if com_topicos else {}
    return None, _do_store() if com_topicos else {}


def claim_atual(st: dict) -> str | None:
    """Whose Wisp claim is the latest. None = unknown. Solo has no claim: this host."""
    if not pair():
        return hosting.HOST
    if hosting.HOST == "pc":
        return hosting.ler_claim().get("host") or "none"
    if hosting.idade_claim_pendente() is not None:
        return "mac"
    return st.get("claim_pc") if st.get("claim_pc") in ("mac", "pc", "none") else None


def estado() -> dict:
    st, idade, le = _local_le()
    reader, _ = leitura(False)
    vivo = bool(st) and idade is not None and idade <= ctl.FRESCO_S
    return {"up": le, "host": hosting.HOST, "state": st.get("state") if st else None, "age_s": idade,
            "reader": reader, "claim": claim_atual(st) if vivo else None}


def _cwd_aqui(*candidatos: str) -> str:
    for c in candidatos:
        if c and os.path.isdir(os.path.expanduser(c)):
            return os.path.expanduser(c)
    return str(cfg().brain)


def topicos_do_bot() -> list[dict] | None:
    """Topics on Telegram now: active notes plus the reader's topics.json. Geral (thread 0) and the system
    topics from the config come with fixed=true. Mirrors and topics whose note is not active are left out.
    None = the other machine reads and its topics.json did not arrive: the list would be incomplete."""
    reader, do_leitor = leitura(True)
    if do_leitor is None:
        return None
    sistema = {0: "Geral", **cfg().system_topics}
    local = do_leitor if reader in (None, hosting.HOST) else _do_store()
    ns = {int(n["thread"]): n for n in notas(com_geral=True) if n["thread"].isdigit()}
    threads = {t for t, n in ns.items() if n["status"] == "active"} | (set(do_leitor) - set(status_das_notas()))
    out = []
    for thread in threads:
        n, b, l = ns.get(thread, {}), do_leitor.get(thread, {}), local.get(thread, {})
        if b.get("meta", {}).get("espelho") or l.get("meta", {}).get("espelho"):
            continue
        datas = [v for v in (b.get("last_used"), (b.get("meta") or {}).get("criado"), l.get("last_used"),
                             topicos._inteiro(n.get("session_last"))) if isinstance(v, (int, float)) and v > 0]
        out.append({"thread": thread,
                    "name": b.get("name") or l.get("name") or sistema.get(thread) or n.get("name", ""),
                    "session_id": b.get("session_id") or n.get("session_id") or l.get("session_id", ""),
                    "cwd": _cwd_aqui(b.get("cwd", ""), l.get("cwd", ""), n.get("cwd", "")),
                    "started": bool((b or l)["started"]) if b or l else n.get("session_started", "false") != "false",
                    "turns": max(n.get("turnos", 0), int(b.get("turns") or 0)),
                    "last_used": max(datas) if datas else None,
                    "host": reader, "session_host": n.get("session_host") or reader,
                    "fixed": thread in sistema})
    if cfg().chat_ids:
        for thread, nome in sistema.items():
            if thread not in threads:
                out.append({"thread": thread, "name": nome, "session_id": "", "cwd": str(cfg().brain),
                            "started": False, "turns": 0, "last_used": None, "host": reader,
                            "session_host": reader, "fixed": True})
    return sorted(out, key=lambda d: d["last_used"] or 0, reverse=True)


# ---- claim (assumir) ----

def _ssh_pc(script: str, prazo: float) -> tuple[int, str]:
    return sessao.ssh_pc(script, prazo)


def esperar(op: str, timeout: float, **args) -> dict:
    id_, rota = ctl.enfileirar(op, **args)
    d = ctl.aguardar(id_, rota, timeout)
    if d is None:
        ctl.cancelar(id_, rota)
        raise RuntimeError(f"o bot não respondeu em {int(timeout)}s (fila {rota}); "
                           "confira quem lê o Telegram: wisp topic listar")
    if not d.get("ok"):
        raise RuntimeError(" ".join(str(d.get("erro") or "o bot recusou o pedido").split()))
    return d


def _do_thread(thread: str, brutos: dict | None, home_pc: str) -> dict | None:
    if not thread or brutos is None:
        return None
    return _do_pc(brutos, home_pc).get(int(thread)) if thread.isdigit() else None


def _trazer_do_pc(thread: str, prazo: float) -> str:
    """Mac already reading: the bot brings the topic's jsonl from the other machine under the topic lock.
    'local' | 'trazida' | 'falhou'."""
    _, home_pc, brutos = ler_pc()
    t = _do_thread(thread, brutos, home_pc)
    if not t or not t["started"] or not sessao.valido(t["session_id"]):
        return "local"
    try:
        d = esperar("trazer", prazo + 5, thread=thread, session_id=t["session_id"],
                    cwd=t["cwd"] or str(cfg().brain), prazo=prazo)
    except RuntimeError as e:
        print(f"aviso: a sessão {t['session_id']} não veio da outra máquina: {e}", file=sys.stderr)
        return "falhou"
    return str(d.get("session") or "local")


def _em_voo_do_mac(thread: str) -> bool:
    marcador = sessao.ler_em_voo()
    return any(k.rsplit(":", 1)[-1] == thread and sessao.em_voo_vivo(marcador, k, time.time())
               for k in (marcador if isinstance(marcador, dict) else {}))


def _pc_offline() -> bool:
    try:
        return asyncio.run(hosting._pc_offline_no_tailscale())
    except Exception:
        return False


def _bot_do_pc_velho(pc_st: str, agora: str) -> bool:
    try:
        st, agora_pc = json.loads(pc_st), int(agora)
    except (json.JSONDecodeError, ValueError):
        return False
    return (isinstance(st, dict) and st.get("state") in ("active", "grace")
            and agora_pc - int(st.get("ts", 0)) <= hosting.FRESCO_S and int(st.get("proto") or 0) < hosting.PROTO)


def _gravar_claim_mac(le: bool) -> tuple[str, str] | None:
    """Mac: writes the claim on the other machine. (previous, ours) raw, to give back; None = left pending."""
    rc, out = (255, "") if _pc_offline() else _ssh_pc(hosting.script_claim("mac"), CLAIM_SSH_S)
    linhas = out.split("\n")
    if rc != 0 or len(linhas) < 4 or not linhas[1].strip():
        if not le:
            raise RuntimeError("não consegui falar com a outra máquina (ssh); a mensagem não foi enviada")
        hosting.gravar_claim_pendente()
        return None
    hosting.apagar_claim_pendente()
    anterior, nosso = linhas[0].strip(), linhas[1].strip()
    if not le and _bot_do_pc_velho(linhas[2].strip(), linhas[3].strip()):
        _devolver_claim(anterior, nosso)
        raise RuntimeError("o bot da outra máquina é de uma versão sem a troca pelo Wisp (reinicie-o); "
                           "a mensagem não foi enviada")
    return anterior, nosso


def _devolver_claim(anterior: str, nosso: str) -> None:
    if hosting.HOST == "pc":
        hosting.restaurar_claim(nosso, anterior)
    else:
        _ssh_pc(hosting.script_restaurar_claim(nosso, anterior), CLAIM_SSH_S)


def assumir(thread: str = "", prazo: float = ASSUMIR_S, passo: float = 0.5) -> dict:
    """This host's Wisp is about to send. Solo: this host is the only reader, done at once. Pair: writes the
    claim, waits for this bot to read and for the topic's session to be here; gives the claim back if it gives up."""
    if not pair():
        return {"ok": True, "reader": hosting.HOST, "waited_s": 0}
    host = hosting.HOST
    t0 = time.monotonic()
    st, idade, le = _local_le()
    ja_lia = le
    if not st or idade is None or idade > ctl.FRESCO_S:
        raise RuntimeError(f"o bot deste {host} não está de pé")
    resto_bloqueio = int(st.get("bloqueado_ate") or 0) - int(time.time())
    if host == "mac" and not le and resto_bloqueio > 0:
        raise RuntimeError(f"o Mac viu outro leitor do Telegram (409) e só volta a ler em {resto_bloqueio} s; "
                           "a mensagem não foi enviada")
    if host == "pc":
        anterior = hosting.CLAIM.read_text().strip() if hosting.ler_claim() else ""
        hosting.gravar_claim("pc")
        devolver = (anterior, hosting.CLAIM.read_text().strip())
    else:
        devolver = _gravar_claim_mac(le)
    while not le:
        if time.monotonic() - t0 >= prazo:
            if devolver:
                _devolver_claim(*devolver)
            raise RuntimeError(f"a outra máquina não soltou a leitura em {int(prazo)} s "
                               "(turno rodando lá?); a mensagem não foi enviada")
        time.sleep(passo)
        _, _, le = _local_le()
    sessao_estado = "local"
    if thread and host == "mac" and not ja_lia:
        sessao_estado = _trazer_do_pc(thread, max(5.0, prazo - (time.monotonic() - t0)))
    elif thread:
        while _em_voo_do_mac(thread):
            if time.monotonic() - t0 >= prazo:
                raise RuntimeError(f"o Mac não entregou a sessão do tópico {thread} em {int(prazo)} s")
            time.sleep(passo)
    return {"ok": True, "reader": host, "waited_s": round(time.monotonic() - t0, 1), "session": sessao_estado}


# ---- puxar ----

def achar(arg: str) -> dict | str:
    ns = notas()
    if arg.isdigit():
        hit = [n for n in ns if n["thread"] == arg]
    else:
        hit = [n for n in ns if arg.lower() in n.get("name", "").lower()]
        exato = [n for n in hit if n.get("name", "").lower() == arg.lower()]
        hit = exato or hit
    if len(hit) == 1:
        return hit[0]
    if not hit:
        return f"nenhum tópico bate com {arg!r} (rode: wisp topic listar)"
    return "mais de um bate: " + ", ".join(f"{n['thread']}={n.get('name')}" for n in hit)


def jsonl_aqui(sid: str, cwd: str, session_host: str) -> None:
    """The topic's jsonl in this machine's projects dir, fetched from the other machine when it is there."""
    if sessao.garantir_local(sid, cwd):
        return
    host = hosting.HOST
    if session_host == host or session_host not in ("mac", "pc"):
        raise RuntimeError(f"o jsonl da sessão {sid} não está em ~/.claude/projects deste {host}")
    if host == "mac":
        sessao.buscar_do_pc(sid, cwd)
        return
    sessao.pedir(sid, topicos.portavel(cwd))
    fim = time.time() + 60
    while time.time() < fim:
        if sessao.garantir_local(sid, cwd):
            return
        time.sleep(2)
    raise RuntimeError("o Mac não enviou a sessão em 60s (bot do Mac de pé? alcançável por ssh?)")


def _texto(content) -> str:
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    return "\n".join(b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text").strip()


def _corta(t: str, n: int) -> str:
    return t if len(t) <= n else t[:n].rstrip() + "…"


def ultima_troca(sid: str) -> tuple[str, str]:
    """(last user line, last agent text reply) of the local jsonl. ('', '') when it cannot be read."""
    try:
        arq = sessao.achar_local(sid)
        if not arq:
            return "", ""
        user = resposta = ""
        for linha in arq.read_text(errors="replace").splitlines():
            try:
                o = json.loads(linha)
            except ValueError:
                continue
            msg = o.get("message") if isinstance(o, dict) else None
            if not isinstance(msg, dict):
                continue
            t = _texto(msg.get("content"))
            if o.get("type") == "user" and not o.get("isMeta") and t and not t.startswith(_WRAPPERS):
                user = t.split(_MARCA_BOT, 1)[-1].strip()
            elif o.get("type") == "assistant" and t:
                resposta = t
        user, resposta = tg_html.plain(user), tg_html.plain(resposta)
        corpo = [l for l in resposta.splitlines() if not l.startswith(_STATUS)]
        return _corta(user, 600), _corta("\n".join(corpo).strip(), 1500)
    except Exception:
        return "", ""


def mostrar_onde_parou(sid: str) -> None:
    user, resposta = ultima_troca(sid)
    if user or resposta:
        print("— onde o tópico parou —")
        if user:
            print(f"Você: {user}")
        if resposta:
            print(f"{cfg().persona}: {resposta}")
        print()


def cmd_puxar(a) -> int:
    if not pair():
        return erro(SO_UMA_MAQUINA)
    n = achar(a.topico)
    if isinstance(n, str):
        return erro(n, 2)
    host = hosting.HOST
    try:
        if n["status"] == "active" and os.environ.get("WISP_TOPIC_THREAD") == str(n["thread"]):
            # inside this topic's own turn the bot holds the lock: waiting for the release would deadlock
            ctl.enfileirar("soltar", thread=n["thread"], destino="terminal-" + host)
            print(f"{n.get('name')}: será solto do Telegram quando esta resposta terminar.\n"
                  f"Depois rode no terminal da máquina que quiser: wisp topic puxar {n['thread']}")
            return 0
        if n["status"] == "active":
            print(f"soltando {n.get('name')} do Telegram…")
            info = esperar("soltar", SOLTAR_S, thread=n["thread"], destino="terminal-" + host)
        else:
            info = {"session_id": n.get("session_id", ""), "cwd": n.get("cwd", ""),
                    "session_host": n.get("session_host", ""), "started": n.get("session_started") != "false"}
        sid = info["session_id"]
        cwd = os.path.expanduser(info.get("cwd") or "~")
        if not os.path.isdir(cwd):
            print(f"aviso: {cwd} não existe aqui; indo para $HOME", file=sys.stderr)
            cwd = str(Path.home())
        if info.get("started", True):
            jsonl_aqui(sid, cwd, info.get("session_host", ""))
    except (RuntimeError, OSError) as e:
        return erro(str(e))
    argv = [cfg().claude_bin or "claude", *(["--resume", sid, RETOMADA] if info.get("started", True) else [])]
    if info.get("started", True):
        mostrar_onde_parou(sid)
    if os.environ.get("CLAUDECODE"):
        print(f"cd {shlex.quote(cwd)} && {shlex.join(argv)}")
        return 0
    os.chdir(cwd)
    os.execvp(argv[0], argv)


# ---- commands ----

def cmd_assumir(a) -> int:
    try:
        d = assumir(str(a.thread or "").strip(), a.timeout)
    except (RuntimeError, OSError) as e:
        return erro(str(e))
    print(claim_json(d) if a.json else
          f"{hosting.HOST} lê o Telegram (esperou {d['waited_s']} s)")
    return 0


def cabecalho() -> str:
    st = hosting.ler_estado_local()
    idade = int(time.time()) - int(st.get("ts", 0)) if st else None
    vivo = bool(st) and idade is not None and idade <= ctl.FRESCO_S
    host = hosting.HOST
    local = f"{host}={st.get('state', '?')}" + ("" if vivo else " (bot parado?)") if st else f"{host}=sem estado"
    partes, leitor = [local], (host if vivo and st.get("state") == "active" else None)
    if pair() and host == "mac":
        pc = asyncio.run(hosting.estado_do_pc())
        partes.append(f"pc={pc or 'sem resposta'}")
        if pc == "active":
            leitor = "pc"
    return f"lendo o Telegram: {leitor or 'ninguém medido'} · " + " · ".join(partes)


def cmd_listar(a) -> int:
    if a.json:
        lista = topicos_do_bot()
        if lista is None:
            return erro("a outra máquina lê o Telegram e o topics.json dela não veio (ssh)")
        print(listar_json(lista))
        return 0
    print(cabecalho())
    ns = notas()
    if not ns:
        print("nenhum tópico ativo ou no terminal")
    for n in ns:
        print(f"{n['thread']:>6}  {n['onde']:<12}  {n['ultimo']:<16}  {n.get('name', '')}")
    return 0


def cmd_status(a) -> int:
    if a.json:
        print(status_json(estado()))
        return 0
    return cmd_listar(a)


def cmd_novo(a) -> int:
    """Empty topic with its own session. No new bot op: `vincular` creates the topic (a mirror of a session that
    never exists) and `desvincular` drops the mirror mark, leaving a plain topic."""
    nome = a.nome.strip()
    if not nome:
        return erro("nome vazio", 2)
    cwd = os.path.abspath(os.path.expanduser(a.cwd or str(cfg().brain)))
    if not os.path.isdir(cwd):
        return erro(f"cwd não existe: {cwd}", 2)
    reader, _ = leitura(False)
    if reader is None:
        return erro(SEM_BOT_NO_PC)
    marca = str(uuid.uuid4())
    try:
        d = esperar("vincular", NOVO_S, session_id=marca, nome=nome, cwd=topicos.portavel(cwd))
        esperar("desvincular", NOVO_S, session_id=marca)
    except (RuntimeError, OSError) as e:
        return erro(str(e))
    if reader == hosting.HOST:
        t = store.Store(store.STORE).get(f"{d['chat']}:{d['thread_id']}")
        sid, nome_t = (t.session_id, t.name) if t else ("", "")
    else:
        _, do_leitor = leitura(True)
        t = (do_leitor or {}).get(int(d["thread_id"]))
        sid, nome_t = (t["session_id"], t["name"]) if t else ("", "")
    if not sessao.valido(sid):
        return erro(f"o tópico {d['thread_id']} foi criado mas não está no topics.json de {reader}")
    print(novo_json(d["thread_id"], sid, cwd, nome_t or nome))
    return 0


def cmd_encerrar(a) -> int:
    """Long wait only while a bot reads: a closing turn can take minutes, but nobody reading never answers."""
    if leitura(False)[0] is None:
        return erro(SEM_BOT_NO_PC)
    try:
        d = esperar("encerrar", ENCERRAR_S, thread=str(a.thread))
    except RuntimeError as e:
        return erro(str(e))
    print(f"encerrado: {d.get('nome') or d.get('thread_id')}")
    return 0


def cmd_falar(a) -> int:
    """Geral is thread 0: the bot posts it without a message_thread_id, so the thread goes through as given."""
    try:
        extra = {"anexos": [str(Path(f).absolute()) for f in a.anexo]} if a.anexo else {}
        d = esperar("falar", FALAR_S, thread=str(a.thread), texto=a.texto, origem=a.origem, **extra)
    except RuntimeError as e:
        return erro(str(e))
    print(f"enviado ao tópico {d.get('thread_id')}; o turno roda no Telegram")
    return 0


def add_parser(sub) -> argparse.ArgumentParser:
    topic = sub.add_parser("topic", help="topics of the Telegram bot")
    cmds = topic.add_subparsers(dest="topic_cmd", required=True)
    pai = argparse.ArgumentParser(add_help=False)
    pai.add_argument("--sem-pull", action="store_true", help="do not pull the brain before reading the notes")
    for nome, f in (("listar", cmd_listar), ("status", cmd_status)):
        p = cmds.add_parser(nome, parents=[pai])
        p.add_argument("--json", action="store_true")
        p.set_defaults(f=f)
    p = cmds.add_parser("novo")
    p.add_argument("--cwd")
    p.add_argument("nome")
    p.set_defaults(f=cmd_novo)
    p = cmds.add_parser("falar", parents=[pai])
    p.add_argument("--origem", default="terminal")
    p.add_argument("--anexo", action="append", default=[], help="file to send with the message (repeatable)")
    p.add_argument("thread")
    p.add_argument("texto")
    p.set_defaults(f=cmd_falar)
    p = cmds.add_parser("encerrar", parents=[pai])
    p.add_argument("thread")
    p.set_defaults(f=cmd_encerrar)
    p = cmds.add_parser("assumir")
    p.add_argument("--thread", default="")
    p.add_argument("--json", action="store_true")
    p.add_argument("--timeout", type=float, default=ASSUMIR_S)
    p.set_defaults(f=cmd_assumir)
    p = cmds.add_parser("puxar", parents=[pai])
    p.add_argument("topico")
    p.set_defaults(f=cmd_puxar)
    return topic


def run(a: argparse.Namespace) -> int:
    if a.topic_cmd in ("listar", "status", "encerrar", "falar", "puxar") and not a.sem_pull \
            and not getattr(a, "json", False):
        pull_vault()
    return a.f(a)
