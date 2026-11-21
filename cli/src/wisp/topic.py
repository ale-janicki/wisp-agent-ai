from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

from wisp_bot import conversa, ctl, hosting, sessao, store, topicos, transcript, unir
from wisp_bot.config import BotConfig, load_settings

COMPARTILHAR_S = 30.0
POSTAR_S = 30.0
ENVIAR_S = 100.0
NOVO_S = 15.0
ENCERRAR_S = 300.0
SEM_BOT = "o bot do Telegram não está rodando (rode: wisp topic listar)"
_LOG = re.compile(r"^- (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) · ", re.M)


def cfg() -> BotConfig:
    return load_settings()


def erro(msg: str, rc: int = 1) -> int:
    print(msg, file=sys.stderr)
    return rc


def status_json(estado: dict) -> str:
    return json.dumps(estado, ensure_ascii=False)


def listar_json(lista: list[dict]) -> str:
    return json.dumps(lista, ensure_ascii=False)


def novo_json(thread, session_id: str, cwd: str, name: str) -> str:
    return json.dumps({"thread": thread, "session_id": session_id, "cwd": cwd, "name": name}, ensure_ascii=False)


def claim_json(d: dict) -> str:
    return json.dumps(d, ensure_ascii=False)


def compartilhado_json(thread, name: str, session_id: str, conversation: str = "") -> str:
    corpo = {"thread": thread, "name": name, "session_id": session_id}
    if conversation:
        corpo["conversation"] = conversation
    return json.dumps(corpo, ensure_ascii=False)


def pull_vault() -> None:
    if not topicos.SYNC:
        return
    env = {k: v for k, v in os.environ.items() if k != "WISP_SKIP_PULL"}
    try:
        subprocess.run([*topicos.SYNC, "pull"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=30, start_new_session=True)
    except (OSError, subprocess.SubprocessError):
        pass


def notas(com_geral: bool = False) -> list[dict]:
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


def _local_le() -> tuple[dict, int | None, bool]:
    st = hosting.ler_estado_local()
    idade = int(time.time()) - int(st.get("ts", 0)) if st else None
    vivo = bool(st) and idade is not None and idade <= ctl.FRESCO_S
    return st, idade, vivo and st.get("state") == "active"


def _do_store() -> dict[int, dict]:
    return {int(t.key.rsplit(":", 1)[-1]): {"name": t.name, "session_id": t.session_id,
                                            "conversation": t.conversation,
                                            "cwd": os.path.expanduser(t.cwd), "started": t.started,
                                            "turns": t.turns, "last_used": t.last_used, "meta": t.meta}
            for t in store.Store(store.STORE).all()}


def estado() -> dict:
    st, idade, le = _local_le()
    return {"up": le, "host": hosting.HOST, "state": st.get("state") if st else None, "age_s": idade,
            "reader": hosting.HOST, "claim": hosting.HOST}


def _cwd_aqui(*candidatos: str) -> str:
    for c in candidatos:
        if c and os.path.isdir(os.path.expanduser(c)):
            return os.path.expanduser(c)
    return str(cfg().brain)


def topicos_do_bot() -> list[dict]:
    reader = hosting.HOST
    do_leitor = local = _do_store()
    sistema = {0: "Geral", **cfg().system_topics}
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
                    "conversation": b.get("conversation") or l.get("conversation") or _conversa_legada(
                        b.get("session_id") or n.get("session_id") or l.get("session_id", "")),
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


def _conversa_legada(session_id: str) -> str:
    if not sessao.valido(session_id):
        return ""
    return conversa.legado(session_id, transcript.Transcripts(cfg().wisp_dir / "conversas"), app_index())


def esperar(op: str, timeout: float, **args) -> dict:
    id_, rota = ctl.enfileirar(op, **args)
    d = ctl.aguardar(id_, rota, timeout)
    if d is None:
        ctl.cancelar(id_, rota)
        raise RuntimeError(f"o bot não respondeu em {int(timeout)}s; confira se ele está de pé: wisp topic status --json")
    if not d.get("ok"):
        raise RuntimeError(" ".join(str(d.get("erro") or "o bot recusou o pedido").split()))
    return d


def cmd_listar(a) -> int:
    if a.json:
        print(listar_json(topicos_do_bot()))
        return 0
    st, _, le = _local_le()
    print(f"bot do Telegram: {'lendo' if le else 'parado' if st else 'sem estado'}")
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
    nome = a.nome.strip()
    if not nome:
        return erro("nome vazio", 2)
    cwd = os.path.abspath(os.path.expanduser(a.cwd or str(cfg().brain)))
    if not os.path.isdir(cwd):
        return erro(f"cwd não existe: {cwd}", 2)
    if not _local_le()[2]:
        return erro(SEM_BOT)
    marca = str(uuid.uuid4())
    try:
        d = esperar("vincular", NOVO_S, session_id=marca, nome=nome, cwd=topicos.portavel(cwd))
        esperar("desvincular", NOVO_S, session_id=marca)
    except (RuntimeError, OSError) as e:
        return erro(str(e))
    t = store.Store(store.STORE).get(f"{d['chat']}:{d['thread_id']}")
    sid, nome_t = (t.session_id, t.name) if t else ("", "")
    if not sessao.valido(sid):
        return erro(f"o tópico {d['thread_id']} foi criado mas não está no topics.json")
    print(novo_json(d["thread_id"], sid, cwd, nome_t or nome))
    return 0


def cmd_encerrar(a) -> int:
    if not _local_le()[2]:
        return erro(SEM_BOT)
    try:
        d = esperar("encerrar", ENCERRAR_S, thread=str(a.thread))
    except RuntimeError as e:
        return erro(str(e))
    print(f"encerrado: {d.get('nome') or d.get('thread_id')}")
    return 0


def cmd_compartilhar(a) -> int:
    if not sessao.valido(a.session):
        return erro(f"session inválida: {a.session!r}", 2)
    cwd = os.path.abspath(os.path.expanduser(a.cwd))
    if not a.nome.strip():
        return erro("nome vazio", 2)
    if a.conversation and not transcript.ID.match(a.conversation):
        return erro(f"conversation inválida: {a.conversation!r}", 2)
    if not _local_le()[2]:
        return erro(SEM_BOT)
    try:
        extra = {"conversation": a.conversation} if a.conversation else {}
        d = esperar("compartilhar", COMPARTILHAR_S, session_id=a.session, cwd=topicos.portavel(cwd), nome=a.nome.strip(),
                    **extra)
    except (RuntimeError, OSError) as e:
        return erro(str(e))
    print(compartilhado_json(d["thread_id"], d.get("name") or a.nome.strip(), a.session, a.conversation or ""))
    return 0


def cmd_postar(a) -> int:
    try:
        corpo = json.loads(sys.stdin.read())
        thread, user, reply = int(corpo["thread"]), str(corpo["user"]), str(corpo["reply"])
        arquivos = corpo.get("arquivos") or []
        conversation = str(corpo.get("conversation") or "")
        turn_at = str(corpo.get("turn_at") or "")
        if not isinstance(arquivos, list) or not all(isinstance(f, str) for f in arquivos):
            raise ValueError
    except (ValueError, KeyError, TypeError, AttributeError):
        return erro('stdin precisa ser JSON {"thread": int, "user": str, "reply": str, "arquivos": [str]?}', 2)
    if not _local_le()[2]:
        return erro(SEM_BOT)
    extra = {"arquivos": arquivos} if arquivos else {}
    if conversation:
        extra["conversation"] = conversation
        if turn_at:
            extra["turn_at"] = turn_at
    try:
        esperar("postar", POSTAR_S, thread=str(thread), user=user, reply=reply, **extra)
    except (RuntimeError, OSError) as e:
        return erro(str(e))
    print(json.dumps({"ok": True}))
    return 0


def cmd_enviar(a) -> int:
    arquivos = [os.path.abspath(os.path.expanduser(f)) for f in a.arquivos]
    if not _local_le()[2]:
        return erro(SEM_BOT)
    try:
        id_, rota = ctl.enfileirar("enviar", thread=a.thread, arquivos=arquivos, legenda=a.legenda)
        d = ctl.aguardar(id_, rota, ENVIAR_S)
    except (RuntimeError, OSError) as e:
        return erro(str(e))
    if d is None:
        print(json.dumps({"ok": True, "pendente": True, "id": id_}))
        print("envio em andamento, não reenvie", file=sys.stderr)
        return 0
    if not d.get("ok"):
        return erro(" ".join(str(d.get("erro") or "o bot recusou o pedido").split()))
    print(json.dumps({"ok": True, "enviados": d.get("enviados", len(arquivos))}))
    return 0


def app_index():
    return Path(os.environ.get("WISP_APP_INDEX") or cfg().conversations_file)


def bot_vivo() -> bool:
    if subprocess.run(["pgrep", "-f", "bin/wisp-bot"], capture_output=True).returncode == 0:
        return True
    job = subprocess.run(["launchctl", "list", "ai.wisp.bot"], capture_output=True, text=True)
    return job.returncode == 0 and '"PID"' in job.stdout


def cmd_unir(a) -> int:
    indice = app_index()
    if not indice.is_file():
        return erro(f"não achei o índice de conversas do app: {indice}")
    wisp_dir = cfg().wisp_dir
    transcritos = transcript.Transcripts(wisp_dir / "conversas")
    try:
        records = json.loads(indice.read_text("utf-8"))
        topicos_ = json.loads(store.STORE.read_text("utf-8")) if store.STORE.exists() else {}
    except (OSError, ValueError) as e:
        return erro(f"não consegui ler os dados: {e}")
    grupos = unir.plano(records, topicos_, transcritos)
    if not grupos:
        print("nada para juntar: cada conversa já tem um id só")
        return 0
    print("\n".join(unir.descrever(grupos, topicos_, transcritos)))
    if not a.aplicar:
        print("\n(só o plano; nada foi gravado. Feche o app, pare o bot e rode de novo com --aplicar)")
        return 0
    if not a.forcar and bot_vivo():
        return erro("o bot do Telegram está rodando: pare o serviço antes de juntar (ou --forcar)")
    if not a.forcar and subprocess.run(["pgrep", "-x", "Wisp"], capture_output=True).returncode == 0:
        return erro("o app do Wisp está aberto: feche antes de juntar (ou --forcar)")
    pasta = unir.aplicar(grupos, indice, store.STORE, transcritos, wisp_dir)
    print(f"\njuntado. cópia de segurança e log em {pasta}")
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
    p = cmds.add_parser("compartilhar")
    p.add_argument("--session", required=True)
    p.add_argument("--cwd", required=True)
    p.add_argument("--nome", required=True)
    p.add_argument("--conversation", help="the Wisp conversation id the app owns; the topic keys on it")
    p.add_argument("--json", action="store_true", help="accepted; the output is always JSON")
    p.set_defaults(f=cmd_compartilhar)
    p = cmds.add_parser("postar")
    p.add_argument("--json", action="store_true", help="accepted; stdin and output are always JSON")
    p.set_defaults(f=cmd_postar)
    p = cmds.add_parser("enviar")
    p.add_argument("--thread", type=int, required=True)
    p.add_argument("--legenda")
    p.add_argument("--json", action="store_true", help="accepted; the output is always JSON")
    p.add_argument("arquivos", nargs="+", metavar="FILE")
    p.set_defaults(f=cmd_enviar)
    p = cmds.add_parser("unir", help="rejoin conversations split by a session id change (plan only without --aplicar)")
    p.add_argument("--aplicar", action="store_true")
    p.add_argument("--forcar", action="store_true", help="skip the app and bot running checks")
    p.set_defaults(f=cmd_unir)
    p = cmds.add_parser("encerrar", parents=[pai])
    p.add_argument("thread")
    p.set_defaults(f=cmd_encerrar)
    return topic


def run(a: argparse.Namespace) -> int:
    if a.topic_cmd in ("listar", "status", "encerrar") and not a.sem_pull \
            and not getattr(a, "json", False):
        pull_vault()
    return a.f(a)
