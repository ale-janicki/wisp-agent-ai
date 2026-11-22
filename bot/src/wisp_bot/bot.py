from __future__ import annotations
import asyncio, fnmatch, functools, html, json, logging, os, re, signal, sys, time
from types import SimpleNamespace
from pathlib import Path

from telegram import (Update, BotCommandScopeAllGroupChats, BotCommandScopeAllPrivateChats,
                      InlineKeyboardButton, InlineKeyboardMarkup)
from telegram.constants import ChatAction, ParseMode
from telegram.error import BadRequest, NetworkError, RetryAfter
from telegram.ext import (Application, CallbackQueryHandler, CommandHandler, MessageHandler, filters,
                          ContextTypes)

from .store import Store
from .engine import Result
from .claude_runner import run as claude_run, strip_status
from . import abrir as abrir_mod
from . import ctl
from . import sessao
from . import topicos
from . import tg_html
from . import hosting, saude, vigilia, polling, session_lock, compartilhar, colheita
from . import hosting, saude, vigilia, polling, session_lock, compartilhar
from . import aprovacoes, codex_runner, conversa
from .transcript import ID as ID_CONVERSA, REBUILT_NOTE, Transcripts, prime, stamp as transcript_stamp, switched_note
from . import engine as engines
from .config import CURRENT as _CFG, ConfigError, _expand, config_path, load_bot_config
from .hosting import HOST

log = logging.getLogger("wisp")

ALLOWED_USER_ID = _CFG.user_id
ALLOWED_CHAT_IDS = set(_CFG.chat_ids)
DEFAULT_CWD = str(_CFG.brain)
PERSONA = _CFG.persona
_QUEM = f"o {_CFG.user_name}" if _CFG.user_name else "o usuario"
TG_LIMIT = 4000
MODELO = os.environ.get("WISP_MODEL", "opus")
transcripts = Transcripts(_CFG.wisp_dir / "conversas", secrets=[_CFG.token], indice=_CFG.conversations_file)

REPOS_ROOT = os.path.expanduser(os.environ.get("WISP_REPOS_ROOT", "~/repos"))
ATALHOS = {"brain": DEFAULT_CWD}

REGRA_GERAL = """
## Canal: Telegram. Voce e o **Geral**.

O Geral e a conversa do dia do usuario: ele despeja tudo aqui. Responda aqui mesmo o
que e conversa ou pergunta, por mais que leve: responder do brain, ler arquivos,
investigar um erro, explicar, salvar algo no brain, uma edicao pontual, um comando.

🔑 **Responder do brain = o brain inteiro.** Leia a nota antes de responder: ela vence
a sua memoria. Busca que morreu com erro no meio da saida (ex.: `no matches found`)
nao e "o brain nao tem" — refaca.

O criterio para abrir topico e o tipo do trabalho, nao o tempo: uma frente especifica
(codigo de um projeto, build/teste, algo que vai ter continuidade propria) vira topico;
o resto fica aqui.

🔑 **Tarefa de verdade vira topico.** Quando o usuario pedir trabalho (corrigir,
construir, investigar), NAO execute aqui:

1. Descubra o suficiente para um briefing preciso: repo (`--dir`), arquivos ou
   areas provaveis, o que o usuario quer, e o plano em 3-6 passos. Seja rapido —
   o agente do topico investiga o resto.
2. Abra o topico (o bot cria em ~2s e dispara o agente de la com o briefing):

  {python} -m wisp_bot.abrir --nome <slug-curto> --dir <repo> --chat {chat} <<'EOF'
  Pedido do usuario: <nas palavras dele>
  Contexto: <o que voce ja sabe: task, caminhos, decisoes>
  Plano: <passos>
  Primeiro passo: <o que fazer agora>
  EOF

3. Responda em 1-2 linhas: qual topico abriu e o plano resumido. So isso.

Atalhos de repo: brain = {brain}; outros em {repos}/<nome>. Na duvida do repo, pergunte.
"""

REGRA_TOPICO = """
## Canal: Telegram, e este topico e um TERMINAL.

Este topico e uma tarefa e funciona como uma sessao de terminal do usuario: vive ate
ele mandar "encerrado" e nunca e zerada no meio. Os comandos dele chegam aqui como no
terminal. Voce segura o plano e o contexto.

- **Rapido e pontual** (1 linha, arquivo conhecido): faca direto.
- **Mudanca real**: despache o subagente `operator` com briefing completo (objetivo,
  caminhos exatos, trecho relevante, regras da casa, teste estreito, o que nao
  tocar); depois o `reviewer` so sobre aquele diff. CHANGES volta para um operator
  novo (max 2 rodadas). Varredura grande: `reader`. Julgue pela evidencia, nunca
  pela alegacao.
- 🔑 **Mensagem que comeca com `/comando` e o usuario rodando o comando no terminal.**
  Execute o comando exatamente como ele esta escrito no arquivo dele, ja, neste turno,
  sem passo que o comando nao tem.

Subagente volta no mesmo turno: reporte o resultado.

🔑 **A nota viva deste topico e `{nota}`** (no brain). Ela e o que deixa o usuario
continuar esta tarefa {maquinas}: a sessao pode acabar, a nota fica. Ao fim de
TODO turno, **antes de escrever a resposta final**, reescreva a secao `## Onde está`
dela em 3-8 linhas: o que esta feito, o que esta sujo no disco e onde, e o proximo
passo. Nao mexa no `## Log` (e do bot) nem no frontmatter, e nao comente a nota na
resposta.
"""

FORCA_ONDE_ESTA = """[regra do topico] O turno anterior fechou sem reescrever a secao
`## Onde está` de {nota}. Reescreva agora (3-8 linhas: o que esta feito, o que esta
sujo no disco e onde, o proximo passo). Nao mexa no Log nem no frontmatter.
Responda so "ok"."""

RETORNO = """[contexto do bot] Desde o seu ultimo turno nesta sessao, este topico andou em
outra maquina. Antes de responder, releia a nota {nota} no brain — o Onde está e as
linhas do Log depois do seu ultimo turno — e continue dali.

Mensagem do usuario:
{msg}"""

CONTINUACAO = """[contexto do bot] Este topico ja tem historia (outra maquina ou sessao
anterior); esta e uma sessao nova em {host}. Antes de responder, leia a nota
{nota} no brain — Briefing, Onde está e o fim do Log — e continue dali.{aviso_cwd}

Mensagem do usuario:
{msg}"""

ALCANCE_S = 15.0
GERAL_HOURS = float(os.environ.get("WISP_GERAL_HOURS", "24"))
PAUSE_MIN = float(os.environ.get("WISP_PAUSE_MIN", "30"))
GERAL_TIMEOUT = int(os.environ.get("WISP_GERAL_TIMEOUT", "3600"))
TOPICO_TIMEOUT = int(os.environ.get("WISP_TOPICO_TIMEOUT", "3600"))
PROGRESSO_S = float(os.environ.get("WISP_PROGRESSO_S", "0"))
TERMINAL = re.compile(r"^(?:terminal|puxa pro terminal|continua no terminal)(?: (?:do |no |de )?(mac|pc))?$")
ENCERRAR = {"encerrado", "encerrada", "encerra", "encerrar", "encerramos", "encerrou", "pode encerrar", "fim"}

RESUMO = """O usuario mandou encerrar este topico. Depois desta resposta a sessao e o topico
sao apagados, entao o que nao for para o brain se perde.

Grave no brain ({brain}) o que esta tarefa produziu, seguindo as convencoes do
brain (convencoes.md na raiz dele):
- Teve substancia (decisao, mudanca, achado, pendencia): nota na pasta certa,
  com o index da pasta. Se ainda ficou algo pendente que precisa mesmo ser
  lembrado, acrescente uma linha em pendencias.md; senao, a nota do topico e a
  memoria.
- Foi trivial (teste, pergunta rapida): nao crie nota; diga que nao havia nada.

Responda em ate 5 linhas: onde gravou e o resumo em uma frase."""

ABERTURA = """Topico aberto pelo Geral a pedido do usuario. Briefing:

{briefing}

Comece mostrando ao usuario o plano em poucas linhas. Execute o que for claro e
reversivel; o que for decisao dele, pergunte antes."""

store = Store()
_locks: dict[str, asyncio.Lock] = {}


_em_curso = 0


def _contado(fn):
    @functools.wraps(fn)
    async def envolto(*args, **kwargs):
        global _em_curso
        _em_curso += 1
        try:
            return await fn(*args, **kwargs)
        finally:
            _em_curso -= 1
    return envolto


def _disparar(coro) -> asyncio.Task:
    global _em_curso
    _em_curso += 1
    t = asyncio.get_running_loop().create_task(coro)

    def _fim(_t) -> None:
        global _em_curso
        _em_curso -= 1
    t.add_done_callback(_fim)
    return t


def lock_for(key: str) -> asyncio.Lock:
    if key not in _locks:
        _locks[key] = asyncio.Lock()
    return _locks[key]


def topic_key(update: Update) -> tuple[str, int | None]:
    chat_id = update.effective_chat.id
    thread_id = getattr(update.effective_message, "message_thread_id", None)
    return f"{chat_id}:{thread_id or 0}", thread_id


async def keep_typing(bot, chat_id: int, thread_id: int | None, parar: asyncio.Event) -> None:
    while not parar.is_set():
        try:
            await bot.send_chat_action(chat_id, ChatAction.TYPING, message_thread_id=thread_id)
        except Exception as e:
            log.warning("typing falhou em %s/%s: %s", chat_id, thread_id, e)
        try:
            await asyncio.wait_for(parar.wait(), timeout=4.0)
        except asyncio.TimeoutError:
            pass


async def progresso(bot, chat_id: int, thread_id: int | None, parar: asyncio.Event,
                    atividade: list[str] | None = None) -> None:
    try:
        await asyncio.wait_for(parar.wait(), timeout=PROGRESSO_S)
        return
    except asyncio.TimeoutError:
        pass
    inicio = time.time() - PROGRESSO_S
    try:
        msg = await bot.send_message(chat_id, "⏳ trabalhando…", message_thread_id=thread_id)
    except Exception as e:
        log.warning("progresso falhou: %s", e)
        return
    log.info("progresso enviado em %s/%s", chat_id, thread_id)
    ultimo = "⏳ trabalhando…"
    while not parar.is_set():
        try:
            await asyncio.wait_for(parar.wait(), timeout=10)
        except asyncio.TimeoutError:
            m, sec = divmod(int(time.time() - inicio), 60)
            texto = f"⏳ trabalhando há {m}m{sec:02d}s"
            if atividade and atividade[0]:
                texto += f" · {atividade[0]}"
            if texto == ultimo:
                continue
            try:
                await msg.edit_text(texto)
                ultimo = texto
            except Exception:
                pass
    try:
        await msg.delete()
        log.info("progresso apagado em %s/%s", chat_id, thread_id)
    except Exception as e:
        log.warning("progresso nao apagou em %s/%s: %s", chat_id, thread_id, e)


async def send(bot, chat, thread_id: int | None, text: str) -> None:
    for part in tg_html.split(tg_html.sanitize(text), TG_LIMIT):
        try:
            await bot.send_message(chat.id, part, parse_mode=ParseMode.HTML,
                                   message_thread_id=thread_id,
                                   disable_web_page_preview=True)
        except Exception as e:
            log.warning("HTML recusado (%s); indo como texto puro", e)
            await bot.send_message(chat.id, tg_html.plain(part),
                                   message_thread_id=thread_id,
                                   disable_web_page_preview=True)


async def reply(update: Update, text: str, thread_id: int | None) -> None:
    await send(update.get_bot(), update.effective_chat, thread_id, text)


def authorized(update: Update) -> bool:
    u = update.effective_user
    if not u or u.id != ALLOWED_USER_ID:
        return False
    if ALLOWED_CHAT_IDS and str(update.effective_chat.id) not in ALLOWED_CHAT_IDS:
        return False
    return True


async def cmd_chatid(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    u = update.effective_user
    if not u or u.id != ALLOWED_USER_ID:
        return
    _, thread_id = topic_key(update)
    await reply(update, f"chat_id: <code>{update.effective_chat.id}</code>\n"
                        f"thread_id: <code>{thread_id or 0}</code>", thread_id)


def is_geral(key: str) -> bool:
    return key.endswith(":0")


def reset_due(topic) -> str | None:
    if not is_geral(topic.key) or not topic.born or not topic.last_used:
        return None
    agora = time.time()
    idade, parado = agora - topic.born, agora - topic.last_used
    if idade > GERAL_HOURS * 3600 and parado > PAUSE_MIN * 60:
        return f"sessao com {int(idade // 3600)}h, {topic.turns} turnos (US$ {topic.cost:.2f})"
    return None


PROPRIOS = [("novo", "abre um tópico: /novo nome [repo] [instrução]"),
            ("fim", "encerra este tópico"), ("status", "sessões vivas"),
            ("reset", "zera a sessão deste tópico"), ("clear", "o mesmo que /reset"),
            ("cwd", "mostra/troca o diretório"),
            ("puxar", "traz uma conversa do app pra cá"),
            ("chatid", "ids do chat e do tópico")]


def comandos_claude() -> dict[str, str]:
    out: dict[str, str] = {}
    fontes = [(f, f.stem) for f in (Path.home() / ".claude/commands").glob("*.md")]
    fontes += [(f, f.parent.name) for f in (Path.home() / ".claude/skills").glob("*/SKILL.md")]
    fontes += _fontes_plugins()
    for f, nome in fontes:
        desc = ""
        try:
            m = re.search(r"^description:\s*(.+)$", f.read_text("utf-8", "replace")[:2000], re.M)
            desc = m.group(1).strip().strip('"\'') if m else ""
        except OSError:
            pass
        out[nome] = desc
    return out


def _fontes_plugins() -> list[tuple[Path, str]]:
    out: list[tuple[Path, str]] = []
    try:
        d = json.loads((Path.home() / ".claude/plugins/installed_plugins.json").read_text("utf-8"))
    except (OSError, ValueError):
        return out
    for chave, instalacoes in (d.get("plugins") or {}).items():
        plugin = chave.split("@", 1)[0]
        for inst in instalacoes[:1]:
            base = Path(inst.get("installPath", ""))
            out += [(f, f"{plugin}:{f.parent.name}") for f in base.glob("skills/*/SKILL.md")]
            out += [(f, f"{plugin}:{f.stem}") for f in base.glob("commands/*.md")]
    return out


def nome_tg(nome: str) -> str:
    return re.sub(r"[-:]", "_", nome).lower()


def mapa_tg(conhecidos: dict[str, str]) -> dict[str, str]:
    mapa: dict[str, str] = {}
    for n in sorted(conhecidos, key=lambda n: ":" in n):
        tg = nome_tg(n)
        if len(tg) > 32 and ":" in n:
            tg = nome_tg(n.split(":", 1)[1])
        if re.fullmatch(r"[a-z0-9_]{1,32}", tg) and tg not in mapa and tg not in dict(PROPRIOS):
            mapa[tg] = n
    return mapa


def comando_claude(msg: str) -> str:
    cab, _, resto = msg.partition(" ")
    nome = cab[1:].split("@", 1)[0]
    conhecidos = comandos_claude()
    if nome not in conhecidos:
        nome = mapa_tg(conhecidos).get(nome, nome)
    return f"/{nome} {resto}".strip()


MENU = ["diagnose", "status", "reset", "cwd", "puxar", "fim"]


def menu_comandos() -> list[tuple[str, str]]:
    proprios = dict(PROPRIOS)
    conhecidos = comandos_claude()
    mapa = mapa_tg(conhecidos)
    curto = {"diagnose": "diagnostica o que está quebrado"}
    menu: list[tuple[str, str]] = []
    for nome in MENU:
        if nome in proprios:
            menu.append((nome, proprios[nome][:100]))
            continue
        tg = next((t for t, n in mapa.items() if n == nome), nome_tg(nome))
        menu.append((tg, (curto.get(nome) or conhecidos.get(nome) or nome)[:100]))
    return menu


def regra_para(key: str, chat_id: int, thread_id: int | None, nota: str = "") -> str:
    if is_geral(key):
        base = REGRA_GERAL.format(chat=chat_id, thread=thread_id or 0, python=sys.executable,
                                  brain=DEFAULT_CWD, repos=REPOS_ROOT)
    else:
        base = REGRA_TOPICO.format(chat=chat_id, thread=thread_id or 0,
                                   maquinas="no PC ou no Mac" if hosting.MODO == "pair" else "nesta máquina",
                                   teto=TOPICO_TIMEOUT // 60,
                                   nota=nota or f"{topicos.REL}/topico-{thread_id}-*.md")
    return base


def topico_local(key: str):
    t = store.get(key)
    if t:
        return t
    tid = key.split(":")[1]
    m = topicos.meta(key) or {}
    nome = m.get("name") or ("Geral" if tid == "0" else f"tópico {tid}")
    cwd = os.path.expanduser(m.get("cwd") or DEFAULT_CWD)
    return store.get_or_create(key, nome, cwd if os.path.isdir(cwd) else DEFAULT_CWD)


def nota_do_topico(key: str, t) -> str:
    return topicos.rel(topicos.garantir(key, t.name, t.cwd))


def contexto_resposta(m) -> str:
    return _contexto_citacao(m)


def _contexto_citacao(m) -> str:
    r = getattr(m, "reply_to_message", None)
    if not r or getattr(r, "forum_topic_created", None) or getattr(r, "forum_topic_edited", None):
        return ""
    quem = f"do {PERSONA}" if (r.from_user and r.from_user.is_bot) else "dele mesmo"
    citado = (m.quote.text if getattr(m, "quote", None) else None) or r.text or r.caption or "(mídia)"
    return f'[o usuario está respondendo a esta mensagem {quem}: "{citado[:800]}"]\n\n'


def _num(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def gravar_sessao(key: str) -> None:
    t = store.get(key)
    if not t:
        return
    topicos.gravar_ponteiro(HOST, key, t.session_id, bool(t.started), t.born, t.last_used,
                            sessao.tamanho_local(t.session_id), t.cwd)


def gravar_sessao_seguro(key: str) -> None:
    try:
        gravar_sessao(key)
    except Exception as e:
        log.warning("gravar_sessao de %s falhou: %s", key, e)


async def alinhar_sessao(key: str, topic):
    m = topicos.meta(key) or {}
    sid = sessao.a_trazer(m, topic.session_id, HOST, sessao.tamanho_local(topic.session_id))
    confirma = m.get("session_id") == topic.session_id and m.get("session_started") == "true"
    if not sid:
        return topic, confirma and topic.started
    started = m.get("session_started") != "false"
    if started and not await asyncio.to_thread(sessao.trazer, sid, topic.cwd, m, HOST):
        log.warning("sessao %s de %s nao veio de %s; usando a local", sid, key, m.get("session_host"))
        return topic, False
    store.seguir_sessao(key, sid, started, _num(m.get("session_born")), _num(m.get("session_last")))
    log.info("topico %s adotou a sessao %s (nota, host %s)", key, sid, m.get("session_host"))
    return store.get(key), started


HANDOVER_S = 20.0


_em_voo_mac: dict[str, dict] = {}
_turnos_mac: dict[str, int] = {}
EM_VOO_TENTATIVAS = 3
EM_VOO_ESPERA_RETRY_S = 10.0


def _marcador_em_voo() -> dict:
    return {k: {"sid": e["sid"], "ts": e["ts"]} for k, e in _em_voo_mac.items()}


async def marcar_em_voo() -> None:
    for t in store.all():
        if _turnos_mac.get(t.key, 0) <= 0:
            continue
        if t.key in _em_voo_mac:
            if not _em_voo_mac[t.key]["fim"]:
                _em_voo_mac[t.key]["ts"] = time.time()
        else:
            _em_voo_mac[t.key] = {"sid": t.session_id, "cwd": t.cwd, "ts": time.time(), "fim": False,
                                  "enviado": False, "falhas": 0, "prox": 0.0}
    if _em_voo_mac:
        if await hosting.gravar_em_voo_pc(_marcador_em_voo()):
            log.info("handover: turno(s) em voo no Mac: %s", ", ".join(_em_voo_mac))
        else:
            log.warning("handover: marcador em-voo nao chegou ao PC")


async def passar_sessoes() -> None:
    await marcar_em_voo()
    cand = {t.session_id: t.cwd for t in store.all()
            if t.started and (topicos.meta(t.key) or {}).get("session_host") == HOST
            and t.key not in _em_voo_mac}
    if not sessao.pendentes(cand):
        return
    tarefas = [topicos.push_agora(HANDOVER_S),
               asyncio.to_thread(sessao.empurrar_mudadas, cand, HANDOVER_S - 3)]
    try:
        await asyncio.wait_for(asyncio.gather(*tarefas, return_exceptions=True), HANDOVER_S)
    except asyncio.TimeoutError:
        log.warning("handover: passou de %ds; cedendo mesmo assim", int(HANDOVER_S))


def _fim_do_turno_mac(key: str) -> None:
    e = _em_voo_mac.get(key)
    if e:
        e["fim"], e["enviado"], e["falhas"], e["prox"] = True, False, 0, 0.0
        t = store.get(key)
        if t:
            e["sid"], e["cwd"] = t.session_id, t.cwd


async def _resolver_em_voo() -> None:
    for key, e in list(_em_voo_mac.items()):
        if e.get("desistiu"):
            if time.time() - e["ts"] > 1800:
                _em_voo_mac.pop(key, None)
            continue
        if not e["fim"] or time.time() < e["prox"]:
            continue
        if not e["enviado"]:
            try:
                await asyncio.to_thread(sessao.enviar_ao_pc, e["sid"], sessao._portavel(e["cwd"]))
            except Exception as ex:
                e["falhas"] += 1
                e["prox"] = time.time() + EM_VOO_ESPERA_RETRY_S
                log.warning("em-voo %s: envio ao PC falhou (%d): %s", key, e["falhas"], ex)
                if e["falhas"] >= EM_VOO_TENTATIVAS:
                    e["desistiu"] = True
                    log.error("em-voo %s: jsonl nao chegou ao PC; marca fica ate expirar", key)
                continue
            await topicos.push_agora()
            e["enviado"], e["falhas"] = True, 0
        if not e["fim"]:
            e["enviado"] = False
            continue
        marcador = {k: v for k, v in _marcador_em_voo().items() if k != key}
        acao, e["falhas"] = sessao.apos_escrita_marcador(
            await hosting.gravar_em_voo_pc(marcador), e["falhas"], EM_VOO_TENTATIVAS)
        if acao == "remover":
            _em_voo_mac.pop(key, None)
            log.info("em-voo %s: sessao entregue ao PC e marca removida", key)
        elif acao == "tentar":
            e["prox"] = time.time() + EM_VOO_ESPERA_RETRY_S
            log.warning("em-voo %s: marcador nao saiu do PC (%d); tento de novo", key, e["falhas"])
        else:
            _em_voo_mac.pop(key, None)
            log.error("em-voo %s: marcador nao saiu do PC apos %d tentativas; largo (expira em 30 min)",
                      key, e["falhas"])


async def _esperar_turno_do_mac(bot, chat, thread_id: int | None, key: str) -> bool:
    if not sessao.em_voo_vivo(sessao.ler_em_voo(), key, time.time()):
        return False
    await send(bot, chat, thread_id, "⏳ terminando o turno anterior no Mac…")
    fim = time.monotonic() + sessao.EM_VOO_ESPERA_S
    while time.monotonic() < fim:
        if not sessao.em_voo_vivo(sessao.ler_em_voo(), key, time.time()):
            log.info("em-voo %s: Mac entregou a sessao; seguindo", key)
            return True
        await asyncio.sleep(2)
    log.warning("em-voo %s: o Mac nao entregou em %ds; seguindo com a copia daqui", key,
                int(sessao.EM_VOO_ESPERA_S))
    sessao.tirar_em_voo(key)
    return True


ESPELHO_AVISO = "este tópico espelha uma sessão do terminal — responda por lá."
_vincular_lock = asyncio.Lock()


def _e_espelho(key: str) -> bool:
    t = store.get(key)
    return bool(t and t.meta.get("espelho"))


def _espelho_de(session_id: str) -> str | None:
    return next((t.key for t in store.all() if t.meta.get("espelho") == session_id), None)


def _marcar_espelho(key: str, session_id: str | None) -> None:
    store.set_meta(key, espelho=session_id)


async def turno(bot, chat, thread_id: int | None, key: str, msg: str, contexto: str = "") -> None:
    if _e_espelho(key):
        log.info("espelho %s: mensagem recusada, a sessao e do terminal", key)
        await send(bot, chat, thread_id, ESPELHO_AVISO)
        return
    sessao.contar_turno(_turnos_mac, key)
    if key in _em_voo_mac:
        _em_voo_mac[key]["fim"] = False
    async def aviso() -> None:
        await send(bot, chat, thread_id, "💤 Mac fechado na bateria — rodo quando abrir.")
    try:
        await vigilia.esperar_poder(aviso)
        vigilia.segurar(key)
        await _turno(bot, chat, thread_id, key, msg, contexto)
    finally:
        ultimo = sessao.soltar_turno(_turnos_mac, key)
        if ultimo:
            vigilia.agendar_soltura(key, vigilia.SEGURA_GERAL_S if is_geral(key) else vigilia.SEGURA_TOPICO_S)
            _fim_do_turno_mac(key)


async def claude_com_memoria(key: str, topic, prompt: str, msg: str, existe: bool, avisar, relock,
                             switched: bool = False, **run_args):
    memoria = None if existe else transcripts.context(topic.session_id)
    transcripts.user(topic.session_id, msg, "telegram")
    if memoria:
        await avisar()
    if switched:
        res = Result(False, "", resume_failed=True)
    else:
        res = await claude_run(prime(memoria, prompt), session_id=topic.session_id, started=existe, **run_args)
    if not res.resume_failed:
        return res, topic
    memoria = transcripts.context(topic.session_id, drop_last_user=True)
    if not memoria:
        res.text = "a sessão do claude não existe mais aqui e não há conversa guardada no Wisp para retomar"
        return res, topic
    antiga = topic.session_id
    novo = store.renovar_sessao(key)
    if novo is None:
        res.text = "a sessão do claude não existe mais aqui e o tópico não existe mais para recomeçar"
        return res, topic
    topic = novo
    await relock(topic.session_id)
    transcripts.rebuilt(antiga, topic.session_id, "claude")
    await avisar()
    res = await claude_run(prime(memoria, prompt), session_id=topic.session_id, started=False, **run_args)
    return res, topic


async def codex_com_memoria(topic, engine, prompt: str, msg: str, avisar, **run_args):
    known = transcripts.engine_session(topic.session_id, "codex")
    started = bool(known) and transcripts.last_engine(topic.session_id) in (None, "codex")
    memoria = None if started else transcripts.context(topic.session_id)
    transcripts.user(topic.session_id, msg, "telegram")
    if memoria:
        await avisar()
    res = await engine.run(prime(memoria, prompt), session_id=known or "", started=started, **run_args)
    if res.resume_failed:
        memoria = transcripts.context(topic.session_id, drop_last_user=True)
        if not memoria:
            res.text = "a sessão do codex não existe mais aqui e não há conversa guardada no Wisp para retomar"
            return res, topic
        await avisar()
        res = await engine.run(prime(memoria, prompt), session_id="", started=False, **run_args)
    if res.ok and res.session_id and res.session_id != known:
        transcripts.engine_started(topic.session_id, res.session_id, "codex", "rebuilt" if known else "new")
    return res, topic


def codex_ou_claude(eng, fallback: str | None, cwd: str):
    if eng.name != "codex":
        return eng, fallback
    conflito = codex_runner.project_conflict(codex_runner.workspace(cwd, _CFG.wisp_dir))
    if not conflito:
        return eng, fallback
    return engines.get("claude"), f"<i>o Codex não roda aqui: {html.escape(conflito)}; esta resposta veio do Claude.</i>"


def session_for(engine_name: str, topic) -> str:
    if engine_name == "codex":
        return transcripts.engine_session(topic.session_id, "codex") or ""
    return topic.session_id


async def _turno(bot, chat, thread_id: int | None, key: str, msg: str, contexto: str = "") -> None:
    topic = topico_local(key)
    lk = lock_for(key)
    if sessao.avisar_fila(lk):
        await send(bot, chat, thread_id, "⏳ ainda estou no turno anterior deste tópico. Entra na fila.")
    parar_a = asyncio.Event()
    typing_a = asyncio.create_task(keep_typing(bot, chat.id, thread_id, parar_a))
    try:
        async with lk:
            if await _esperar_turno_do_mac(bot, chat, thread_id, key):
                try:
                    await topicos.pull()
                except Exception as e:
                    log.warning("pull apos em-voo de %s falhou: %s", key, e)
            topic, segue = await alinhar_sessao(key, topic)
    except Exception as e:
        log.warning("alinhar_sessao de %s falhou: %s", key, e)
        topic, segue = topico_local(key), False
    finally:
        parar_a.set()
        await typing_a
    motivo = reset_due(topic)
    if motivo:
        log.info("reset automatico em %s: %s", key, motivo)
        try:
            conversa.garantir(store, transcripts, key)
        except Exception as e:
            log.warning("vinculo da conversa de %s falhou: %s", key, e)
        store.reset(key)
        topic = store.get_or_create(key, topic.name, topic.cwd)
    try:
        conversa.garantir(store, transcripts, key, "reset" if motivo else "new")
    except Exception as e:
        log.warning("vinculo da conversa de %s falhou: %s", key, e)

    nota = nota_do_topico(key, topic)
    if nota and motivo:
        gravar_sessao_seguro(key)
    prompt = contexto + msg
    m = topicos.meta(key) or {} if nota else {}
    modo = sessao.decidir_prompt(segue, motivo, nota, topic.started, bool(m.get("_tem_historia")),
                          topicos.ultimo_host(key) if nota else None, HOST)
    if modo == "continuacao":
        cwd_nota = os.path.expanduser(m.get("cwd") or "")
        aviso = (f"\n⚠️ O cwd original ({m.get('cwd')}) nao existe nesta maquina; "
                 f"voce esta em {topic.cwd}.") if cwd_nota and not os.path.isdir(cwd_nota) else ""
        prompt = CONTINUACAO.format(host=HOST, nota=nota, aviso_cwd=aviso, msg=contexto + msg)
    elif modo == "retorno":
        prompt = RETORNO.format(nota=nota, msg=contexto + msg)

    exige = bool(nota) and not is_geral(key)
    nota_abs = str(topicos.BRAIN / nota) if exige else ""

    async def _aviso_app() -> None:
        await send(bot, chat, thread_id, "⏳ respondendo no app, esta vem logo depois")
    async with lk, session_lock.guard(topic.session_id, _aviso_app) as held:
        base = topicos.onde_esta_hash(key) if exige else ""
        env = {"WISP_TOPIC_NOTE": nota_abs, "WISP_TOPIC_BASE": base} if exige else {}
        env["WISP_TOPIC_THREAD"] = str(thread_id or 0)
        if thread_id is not None:
            env["WISP_TELEGRAM_THREAD"] = str(thread_id)
        env = env or None
        parar = asyncio.Event()
        aviso_onde = ""
        typing = asyncio.create_task(keep_typing(bot, chat.id, thread_id, parar))
        atividade = [""]
        def on_event(rotulo: str) -> None:
            atividade[0] = rotulo
        async def on_text(texto: str) -> None:
            t = tg_html.plain(strip_status(texto)).strip()
            if len(t) >= 3:
                atividade[0] = "💬 " + t.split("\n", 1)[0][:120]
                log.info("parcial no progresso em %s/%s (%d chars)", chat.id, thread_id, len(t))
        prog = asyncio.create_task(progresso(bot, chat.id, thread_id, parar, atividade))
        try:
            eng, fallback = await engines.resolve(_CFG.wisp_dir)
            eng, fallback = codex_ou_claude(eng, fallback, topic.cwd)
            if fallback:
                await send(bot, chat, thread_id, fallback)
            existe = topic.started or sessao.achar_local(topic.session_id) is not None
            anterior = transcripts.last_engine(topic.session_id)
            trocou = anterior not in (None, eng.name)
            async def avisar_retomada() -> None:
                await send(bot, chat, thread_id, switched_note(eng.name) if trocou else REBUILT_NOTE)
            comum = dict(cwd=topic.cwd, model=MODELO, timeout=GERAL_TIMEOUT if is_geral(key) else TOPICO_TIMEOUT,
                         extra_prompt=regra_para(key, chat.id, thread_id, nota), disallowed="",
                         env=env, on_event=on_event, on_text=on_text)
            if eng.name == "claude":
                res, topic = await claude_com_memoria(
                    key, topic, prompt, msg, existe, avisar_retomada, held.move, switched=trocou and existe,
                    on_permission=pedir_permissao(bot, chat.id, thread_id), **comum)
            else:
                res, topic = await codex_com_memoria(topic, eng, prompt, msg, avisar_retomada,
                                                     on_permission=pedir_permissao(bot, chat.id, thread_id), **comum)
            if not res.ok and "dormiu no meio" in res.text:
                async def aviso_dormiu() -> None:
                    await send(bot, chat, thread_id, "💤 Mac fechado na bateria — rodo quando abrir.")
                await vigilia.esperar_poder(aviso_dormiu)
                if eng.name == "claude":
                    existe = topic.started or sessao.achar_local(topic.session_id) is not None
                    res = await claude_run("Continue de onde parou." if existe else prompt,
                                           session_id=topic.session_id, started=existe,
                                           on_permission=pedir_permissao(bot, chat.id, thread_id), **comum)
                else:
                    sessao_codex = session_for("codex", topic)
                    res = await eng.run("Continue de onde parou." if sessao_codex else prompt,
                                        session_id=sessao_codex, started=bool(sessao_codex),
                                        on_permission=pedir_permissao(bot, chat.id, thread_id), **comum)
            if res.ok and exige and topicos.onde_esta_hash(key) == base:
                log.warning("Onde está nao atualizado em %s: forcando", key)
                f = await (claude_run if eng.name == "claude" else eng.run)(
                    FORCA_ONDE_ESTA.format(nota=nota_abs), session_id=session_for(eng.name, topic),
                    cwd=topic.cwd, started=True, model=MODELO, timeout=300, env=env,
                    on_permission=pedir_permissao(bot, chat.id, thread_id))
                if f.ok:
                    store.bump(key, f.cost_usd)
                if topicos.onde_esta_hash(key) == base:
                    log.error("Onde está segue velho em %s depois de forcar", key)
                    aviso_onde = "⚠️ <i>não consegui atualizar o Onde está da nota do tópico</i>"
                    res.text += "\n\n" + aviso_onde
        finally:
            parar.set()
            await typing
            await prog
        if res.ok:
            store.mark_started(key)
            store.bump(key, res.cost_usd)
            resposta = res.text.removesuffix("\n\n" + aviso_onde) if aviso_onde else res.text
            transcripts.assistant(topic.session_id, resposta, "telegram", res.engine, res.model)
            await send(bot, chat, thread_id, res.text)
        else:
            await send(bot, chat, thread_id, f"<b>falhou</b>\n<pre>{html.escape(res.text)}</pre>")
        aviso_pasta = transcripts.take_notice()
        if aviso_pasta:
            await send(bot, chat, thread_id, f"<i>{html.escape(aviso_pasta)}</i>")
        if nota:
            try:
                topicos.anexar_log(key, HOST, msg, res.text, ok=res.ok)
                if res.ok:
                    gravar_sessao(key)
                topicos.push_logo()
            except Exception as e:
                log.warning("log do topico %s falhou: %s", key, e)


async def on_message(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorized(update):
        log.warning("ignorado: user_id=%s", getattr(update.effective_user, "id", None))
        return
    msg = (update.effective_message.text or "").strip()
    if not msg:
        return

    await processa(update, ctx, msg, contexto_resposta(update.effective_message))


ANEXOS_DIR = _CFG.anexos
ANEXO_JANELA = 3.0
ANEXO_SEM_TEXTO = "(sem texto — veja o que é e me diga)"
ANEXO_FOTO = (".jpg", ".jpeg", ".png", ".webp")
ANEXOS_MAX = 10
ANEXO_MAX_BYTES = 50 * 1024 * 1024
ANEXO_FOTO_MAX_BYTES = 10 * 1024 * 1024
ANEXO_LEGENDA_MAX = 1024
_anexos_pendentes: dict[str, dict] = {}


ANEXO_TENTATIVAS = 3
ANEXO_BACKOFF = (2, 5)
_TIMEOUTS = dict(connect_timeout=30, read_timeout=60, write_timeout=60)


async def _baixar_anexo(midia, destino: Path) -> None:
    for tentativa in range(1, ANEXO_TENTATIVAS + 1):
        try:
            f = await midia.get_file(**_TIMEOUTS)
            await f.download_to_drive(destino, **_TIMEOUTS)
            return
        except NetworkError as e:
            if isinstance(e, BadRequest) or tentativa == ANEXO_TENTATIVAS:
                raise
            log.warning("anexo %s: tentativa %d/%d falhou (%s), repetindo",
                        midia.file_id, tentativa, ANEXO_TENTATIVAS, e)
            await asyncio.sleep(ANEXO_BACKOFF[tentativa - 1])


async def on_attachment(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorized(update):
        return
    m = update.effective_message
    key, thread_id = topic_key(update)
    video = m.video or m.video_note
    midia = m.document or video or (m.photo[-1] if m.photo else None)
    try:
        if video:
            nome = getattr(video, "file_name", None) or f"video-{m.message_id}.mp4"
        else:
            nome = (m.document.file_name if m.document else None) or (
                f"arquivo-{m.message_id}" if m.document else f"foto-{m.message_id}.jpg")
        destino_dir = ANEXOS_DIR / time.strftime("%Y-%m-%d")
        destino_dir.mkdir(parents=True, exist_ok=True)
        destino = destino_dir / f"{m.message_id}-{nome}"
        await _baixar_anexo(midia, destino)
        item = f"- {destino} ({nome}, {destino.stat().st_size} bytes)"
        log.info("anexo em %s: %s", key, destino)
    except Exception as e:
        log.warning("anexo em %s falhou: %s (message_id=%s file_id=%s file_unique_id=%s)", key, e,
                    m.message_id, getattr(midia, "file_id", None), getattr(midia, "file_unique_id", None))
        rotulo = getattr(m.document, "file_name", None) or ("video" if video else "foto")
        item = f"- {rotulo}: nao consegui baixar ({e})"

    p = _anexos_pendentes.setdefault(key, {"itens": [], "legenda": [], "contexto": "",
                                           "update": update, "tarefa": None})
    p["itens"].append(item)
    if m.caption:
        p["legenda"].append(m.caption.strip())
        p["contexto"] = p["contexto"] or contexto_resposta(m)
    if p["tarefa"]:
        p["tarefa"].cancel()
    p["tarefa"] = _disparar(_despachar_anexos(key, ctx))


async def _despachar_anexos(key: str, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    try:
        await asyncio.sleep(ANEXO_JANELA)
    except asyncio.CancelledError:
        return
    p = _anexos_pendentes.pop(key, None)
    if not p:
        return
    msg = bloco_anexos("Telegram", p["itens"], "\n".join(p["legenda"]))
    await processa(p["update"], ctx, msg, p["contexto"])


def bloco_anexos(origem: str, itens: list[str], texto: str) -> str:
    return (f"[{_QUEM} enviou {len(itens)} arquivo(s) pelo {origem}, ja salvos nesta maquina:\n"
            + "\n".join(itens) + "]\n\n" + (texto or ANEXO_SEM_TEXTO))


NEGADOS_NOMES = (".env", ".netrc", ".git-credentials", ".pgpass", ".npmrc", ".pypirc")
NEGADOS_GLOBS = (".env.*", "id_rsa*", "id_ed25519*", "id_ecdsa*", "*.pem", "*.p12", "*.pfx",
                 "*.keychain", "*.keychain-db")
NEGADOS_MARCADOR = b"PRIVATE KEY-----"
NEGADOS_BYTES = 4096
NEGADOS_PASTAS = (".ssh", ".gnupg", ".aws", "Library/Keychains", ".config/wisp", ".kube", ".docker",
                  ".config/gcloud", ".azure", ".config/gh", ".password-store")


def _negados() -> list[Path]:
    home = Path.home()
    negados = [home / pasta for pasta in NEGADOS_PASTAS]
    try:
        tg = json.loads(config_path().read_text("utf-8")).get("telegram") or {}
        if tg.get("token_file"):
            negados.append(_expand(str(tg["token_file"]), os.environ))
    except (OSError, ValueError, AttributeError):
        pass
    return [p.resolve() for p in negados]


def _nome_negado(real: Path) -> bool:
    nome = real.name.casefold()
    return nome in NEGADOS_NOMES or any(fnmatch.fnmatchcase(nome, g) for g in NEGADOS_GLOBS)


def _conteudo_negado(real: Path) -> str | None:
    try:
        with real.open("rb") as f:
            cabeca = f.read(NEGADOS_BYTES)
    except OSError:
        return "nao pode ser lido"
    return "contem uma chave privada" if NEGADOS_MARCADOR in cabeca else None


def _fica_em_negado(real: Path, negados: list[Path]) -> bool:
    if _nome_negado(real):
        return True
    fold = Path(str(real).casefold())
    if any(fold.is_relative_to(Path(str(n).casefold())) for n in negados):
        return True
    for ancestral in (real, *real.parents):
        for n in negados:
            try:
                if os.path.samefile(ancestral, n):
                    return True
            except OSError:
                continue
    return False


def arquivos_validos(brutos) -> list[tuple[Path, int]]:
    if not isinstance(brutos, list) or not 1 <= len(brutos) <= ANEXOS_MAX:
        raise ValueError(f"arquivos precisa ser uma lista de 1 a {ANEXOS_MAX} caminhos")
    negados = _negados()
    out = []
    for bruto in brutos:
        p = Path(str(bruto))
        if not p.is_absolute():
            raise ValueError(f"arquivo recusado: {p.name or bruto!r} precisa de caminho absoluto")
        real = p.resolve()
        if _fica_em_negado(real, negados):
            raise ValueError(f"arquivo recusado: {real.name} fica numa pasta protegida")
        if not real.is_file():
            raise ValueError(f"arquivo recusado: {real.name or bruto!r} nao e um arquivo comum")
        motivo = _conteudo_negado(real)
        if motivo:
            raise ValueError(f"arquivo recusado: {real.name} {motivo}")
        try:
            tamanho = real.stat().st_size
            with real.open("rb"):
                pass
        except OSError:
            raise ValueError(f"arquivo recusado: {real.name} nao pode ser lido") from None
        if tamanho > ANEXO_MAX_BYTES:
            raise ValueError(f"arquivo recusado: {real.name} passa de {ANEXO_MAX_BYTES // (1024 * 1024)} MB")
        out.append((real, tamanho))
    return out


async def _postar_arquivo(bot, chat_id: int, tid: int | None, p: Path, tamanho: int, legenda: str | None) -> None:
    async def uma_vez(extra: dict) -> None:
        with p.open("rb") as f:
            if p.suffix.lower() in ANEXO_FOTO and tamanho <= ANEXO_FOTO_MAX_BYTES:
                try:
                    await bot.send_photo(chat_id, f, message_thread_id=tid, **extra, **_TIMEOUTS)
                    return
                except BadRequest as e:
                    if "caption" in extra and "parse" in str(e).lower():
                        raise
                    log.warning("arquivo %s recusado como foto (%s); indo como documento", p.name, e)
                    f.seek(0)
            await bot.send_document(chat_id, f, filename=p.name, message_thread_id=tid, **extra, **_TIMEOUTS)

    async def tentar() -> None:
        if not legenda:
            return await uma_vez({})
        html_ = tg_html.sanitize(legenda[:ANEXO_LEGENDA_MAX])
        if len(tg_html.plain(html_)) > ANEXO_LEGENDA_MAX:
            html_ = tg_html.sanitize(tg_html.plain(html_)[:ANEXO_LEGENDA_MAX])
        try:
            await uma_vez({"caption": html_, "parse_mode": ParseMode.HTML})
        except BadRequest as e:
            if "parse" not in str(e).lower():
                raise
            log.warning("legenda HTML recusada (%s); indo como texto puro", e)
            await uma_vez({"caption": tg_html.plain(html_)[:ANEXO_LEGENDA_MAX]})
    try:
        await tentar()
    except RetryAfter as e:
        espera = e.retry_after.total_seconds() if hasattr(e.retry_after, "total_seconds") else float(e.retry_after)
        log.warning("flood control ao enviar %s: esperando %ss", p.name, espera)
        await asyncio.sleep(espera)
        await tentar()


async def _postar_arquivos(bot, chat_id: int, tid: int | None, itens: list[tuple[Path, int]],
                           legenda: str | None) -> None:
    for i, (p, tamanho) in enumerate(itens):
        await _postar_arquivo(bot, chat_id, tid, p, tamanho, legenda if i == 0 else None)


async def _recebido(m) -> None:
    try:
        await m.set_reaction("👀")
    except Exception as e:
        log.warning("reacao falhou: %s", e)


async def processa(update: Update, ctx: ContextTypes.DEFAULT_TYPE, msg: str, contexto: str = "") -> None:
    asyncio.create_task(_recebido(update.effective_message))
    key, thread_id = topic_key(update)
    if msg.lower().strip(" .!") in ENCERRAR:
        await encerrar(update, ctx)
        return
    m = TERMINAL.match(msg.lower().strip(" .!"))
    if m:
        await cmd_terminal(update, ctx, "terminal-" + (m.group(1) or HOST))
        return
    await turno(ctx.bot, update.effective_chat, thread_id, key, msg, contexto)


async def on_passthrough(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorized(update):
        return
    msg = (update.effective_message.text or "").strip()
    if msg:
        await processa(update, ctx, comando_claude(msg))


async def cmd_status(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorized(update):
        return
    _, thread_id = topic_key(update)
    ts = store.all()
    if not ts:
        await reply(update, "nenhum tópico com sessão ainda.", thread_id)
        return
    linhas = [f"<b>{html.escape(t.name)}</b> — <code>{html.escape(t.cwd)}</code>\n"
              f"  {t.turns} turnos · US$ {t.cost:.2f}"
              f"{f' · sessão com {int((time.time() - t.born) // 3600)}h/{int(GERAL_HOURS)}h' if is_geral(t.key) and t.born else ''}"
              f"{' · ocupado' if lock_for(t.key).locked() else ''}" for t in ts]
    total = sum(t.cost for t in ts)
    await reply(update, "\n".join(linhas) + f"\n\n<i>total em sessões vivas: US$ {total:.2f}"
                        f" · respondendo do <b>{HOST}</b></i>",
                thread_id)


async def cmd_reset(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorized(update):
        return
    key, thread_id = topic_key(update)
    try:
        conversa.garantir(store, transcripts, key)
    except Exception as e:
        log.warning("vinculo da conversa de %s falhou: %s", key, e)
    store.reset(key)
    try:
        conversa.garantir(store, transcripts, key, "reset")
    except Exception as e:
        log.warning("vinculo da conversa de %s falhou: %s", key, e)
    try:
        gravar_sessao(key)
        topicos.push_logo()
    except Exception as e:
        log.warning("gravar_sessao de %s falhou: %s", key, e)
    await reply(update, "sessão zerada neste tópico. O contexto anterior foi embora.", thread_id)


async def cmd_cwd(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorized(update):
        return
    key, thread_id = topic_key(update)
    if not ctx.args:
        t = topico_local(key)
        await reply(update, f"cwd atual: <code>{html.escape(t.cwd)}</code>", thread_id)
        return
    novo = os.path.expanduser(" ".join(ctx.args))
    if not os.path.isdir(novo):
        await reply(update, f"não existe: <code>{html.escape(novo)}</code>", thread_id)
        return
    topico_local(key)
    store.set_cwd(key, novo)
    topicos.set_cwd(key, novo)
    await reply(update, f"cwd deste tópico agora é <code>{html.escape(novo)}</code>", thread_id)


def resolve_dir(arg: str) -> str | None:
    if arg in ATALHOS:
        return os.path.expanduser(ATALHOS[arg])
    cand = os.path.expanduser(arg)
    if os.path.isdir(cand):
        return cand
    cand = os.path.join(REPOS_ROOT, arg)
    return cand if os.path.isdir(cand) else None


async def cmd_novo(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorized(update):
        return
    _, thread_id = topic_key(update)
    chat = update.effective_chat

    if not ctx.args:
        atalhos = " · ".join(sorted(ATALHOS))
        await reply(update, f"uso: <code>/novo &lt;nome&gt; [repo] [instrução...]</code>\n"
                            f"atalhos: {atalhos}", thread_id)
        return
    if chat.type != "supergroup":
        await reply(update, "tópicos só existem em supergrupo com <b>Topics</b> ligado. "
                            "No privado só existe esta conversa.", thread_id)
        return

    nome, resto = ctx.args[0], ctx.args[1:]
    cwd = DEFAULT_CWD
    if resto and (d := resolve_dir(resto[0])):
        cwd, resto = d, resto[1:]
    instrucao = " ".join(resto).strip()

    try:
        await abrir_topico(ctx.bot, chat.id, nome, cwd, instrucao, briefing=instrucao)
    except Exception as e:
        await reply(update, f"não consegui criar o tópico: <code>{html.escape(str(e))}</code>\n"
                            "confere se eu sou <b>admin</b> com permissão de gerenciar tópicos.", thread_id)
        return
    await reply(update, f"criado: <b>{html.escape(nome)}</b>"
                        + (" — já mandei a tarefa" if instrucao else ""), thread_id)


async def abrir_topico(bot, chat_id: int, nome: str, cwd: str, instrucao: str,
                       cabecalho: str = "", briefing: str = "") -> int:
    ft = await bot.create_forum_topic(chat_id=chat_id, name=nome[:128])
    tid = ft.message_thread_id
    key = f"{chat_id}:{tid}"
    store.get_or_create(key, name=nome, cwd=cwd)
    topicos.garantir(key, nome, cwd, briefing)
    topicos.push_logo()
    chat = SimpleNamespace(id=chat_id)
    await send(bot, chat, tid, f"<b>{html.escape(nome)}</b>\ncwd: <code>{html.escape(cwd)}</code>"
                               + (f"\n\n{cabecalho}" if cabecalho else ""))
    if instrucao:
        _disparar(turno(bot, chat, tid, key, instrucao))
    return tid


async def abridor(app) -> None:
    while True:
        await asyncio.sleep(2)
        for p in abrir_mod.pendentes():
            try:
                os.unlink(p["_file"])
                await abrir_topico(
                    app.bot, int(p["chat_id"]), p["nome"], p["cwd"],
                    ABERTURA.format(briefing=p["briefing"]),
                    cabecalho=f"<i>aberto pelo Geral</i>\n<pre>{html.escape(p['briefing'][:3000])}</pre>",
                    briefing=p["briefing"])
            except Exception as e:
                log.warning("abrir topico falhou (%s): %s", p.get("nome"), e)
                try:
                    await app.bot.send_message(int(p["chat_id"]),
                        f"não consegui abrir o tópico <b>{html.escape(str(p.get('nome')))}</b>: "
                        f"<code>{html.escape(str(e))}</code>", parse_mode=ParseMode.HTML)
                except Exception:
                    pass


def _chat_principal() -> int | None:
    return int(sorted(ALLOWED_CHAT_IDS)[0]) if ALLOWED_CHAT_IDS else None


_aprovacoes: aprovacoes.Aprovacoes | None = None


def pedir_permissao(bot, chat_id: int, thread_id: int | None):
    """O `on_permission` dos turnos neste chat/topico, do claude (can_use_tool) e do codex (broker do e-mail): o pedido
    vira um cartao Permitir/Negar para o dono. Sem o canal (bot ainda subindo) o pedido e negado."""
    if _aprovacoes is None:
        return None
    async def pedir(req: dict) -> str | None:
        return await _aprovacoes.pedir(chat_id, thread_id, req)
    return pedir


async def on_aprovacao(update, context) -> None:
    if _aprovacoes is None:
        await update.callback_query.answer("expirou ou já respondido")
    else:
        await _aprovacoes.pressionou(update, context)


async def _post_init(app) -> None:
    for t in store.all():
        nome = _CFG.system_topics.get(_thread_de(t.key))
        if nome and t.name != nome:
            store.renomear(t.key, nome)
    app.bot_data["abridor"] = asyncio.create_task(abridor(app))
    app.bot_data["controlador"] = asyncio.create_task(controlador(app))
    global _aprovacoes
    _aprovacoes = aprovacoes.Aprovacoes(app.bot, ALLOWED_USER_ID)


async def _ao_ativar(app, motivo: str) -> None:
    await topicos.pull()
    try:
        menu = menu_comandos()
        await app.bot.set_my_commands(menu)
        for escopo in (BotCommandScopeAllGroupChats(), BotCommandScopeAllPrivateChats()):
            await app.bot.set_my_commands(menu, scope=escopo)
        log.info("menu publicado: %d comandos", len(menu))
    except Exception as e:
        log.warning("set_my_commands falhou: %s", e)


async def _ao_desativar(app, motivo: str) -> None:
    vigilia.soltar_todas()


async def cmd_fim(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorized(update):
        return
    await encerrar(update, ctx)


async def encerrar(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    key, thread_id = topic_key(update)
    if not thread_id:
        await reply(update, "o <b>Geral</b> não fecha — ele é a conversa contínua. "
                            "Use <code>/reset</code> se quiser só zerar o contexto.", thread_id)
        return

    if lock_for(key).locked():
        await reply(update, "tem turno rodando agora. Espera terminar ou usa <code>/fim</code> de novo depois.",
                    thread_id)
        return

    t = topico_local(key)
    chat_id = update.effective_chat.id
    if t.started and t.turns:
        await reply(update, "encerrando: gravando o resumo no brain antes de apagar o tópico…", thread_id)
    _disparar(fechar(ctx.bot, chat_id, thread_id, key))


async def _apagar_topico(bot, chat_id: int, thread_id: int) -> str:
    try:
        await bot.delete_forum_topic(chat_id=chat_id, message_thread_id=thread_id)
        return "apagado"
    except Exception as e:
        log.warning("nao consegui apagar o topico %s: %s", thread_id, e)
        try:
            await bot.close_forum_topic(chat_id=chat_id, message_thread_id=thread_id)
            return "arquivado (sem permissão de apagar)"
        except Exception as e2:
            log.warning("nem arquivar o topico %s: %s", thread_id, e2)
            return "ficou aberto (sem permissão)"


async def fechar(bot, chat_id: int, thread_id: int, key: str) -> None:
    chat = SimpleNamespace(id=chat_id)
    async with lock_for(key):
        t = topico_local(key)
        texto = ""
        if t.started and t.turns:
            async def _aviso_app() -> None:
                await send(bot, chat, thread_id, "⏳ respondendo no app, o resumo vem logo depois")
            async with session_lock.guard(t.session_id, _aviso_app):
                ultimo = transcripts.last_engine(t.session_id)
                codex_sid = session_for("codex", t) if ultimo == "codex" else ""
                run_resumo = engines.get("codex").run if codex_sid else claude_run
                res = await run_resumo(RESUMO.format(brain=DEFAULT_CWD),
                                       session_id=codex_sid or t.session_id,
                                       cwd=t.cwd, started=True, model=MODELO,
                                       timeout=TOPICO_TIMEOUT,
                                       extra_prompt=regra_para(key, chat_id, thread_id),
                                       on_permission=pedir_permissao(bot, chat_id, thread_id))
            if not res.ok:
                await send(bot, chat, thread_id,
                           f"<b>não encerrei</b>: o resumo falhou, então o tópico fica.\n"
                           f"<pre>{html.escape(res.text[:1500])}</pre>\nManda <code>encerrado</code> de novo.")
                return
            store.bump(key, res.cost_usd)
            texto = res.text

        t = store.drop(key)
        vigilia.soltar(key)
        topicos.set_status(key, "encerrado")
        topicos.push_logo()

    destino = await _apagar_topico(bot, chat_id, thread_id)

    nome = html.escape(t.name) if t else f"tópico {thread_id}"
    msg = f"✅ <b>{nome}</b> encerrado e {destino}" + (f" — {t.turns} turnos" if t else "")
    if texto:
        msg += f"\n\n{texto}"
    await send(bot, chat, None, msg)


def _host_nome(h: str) -> str:
    return "Mac" if h.endswith("mac") else "PC"


def _thread_de(key: str) -> int:
    return int(key.rsplit(":", 1)[-1])


def _key_da_thread(thread) -> str | None:
    for t in store.all():
        if t.key.rsplit(":", 1)[-1] == str(thread):
            return t.key
    chat = _chat_principal()
    key = f"{chat}:{thread}" if chat else None
    return key if key and topicos.meta(key) else None


async def soltar_topico(bot, chat_id: int, thread_id: int, key: str, destino: str) -> dict:
    if destino not in ctl.destinos():
        raise ValueError(f"destino invalido: {destino}")
    if not thread_id:
        raise ValueError("o Geral nao vai para o terminal")
    chat = SimpleNamespace(id=chat_id)
    async with lock_for(key):
        t = store.get(key)
        if t is None:
            m = topicos.meta(key) or {}
            if m.get("status") == "terminal" and m.get("session_id"):
                return {"ok": True, "session_id": m["session_id"], "cwd": m.get("cwd", ""),
                        "session_host": m.get("session_host", ""), "nome": m.get("name", ""),
                        "started": m.get("session_started") != "false", "thread_id": thread_id}
            raise ValueError(f"o topico {thread_id} nao esta no Telegram")
        await send(bot, chat, thread_id, f"↪ continuando no terminal do {_host_nome(destino)}")
        store.drop(key)
        topicos.garantir(key, t.name, t.cwd)
        topicos.set_campos(key, status="terminal", onde=destino)
        topicos.gravar_ponteiro(HOST, key, t.session_id, bool(t.started), t.born, time.time(),
                                sessao.tamanho_local(t.session_id), t.cwd)
        topicos.push_logo()
    onde_tg = await _apagar_topico(bot, chat_id, thread_id)
    await send(bot, chat, None, texto_saiu_do_telegram(t, thread_id, destino, onde_tg))
    return {"ok": True, "session_id": t.session_id, "cwd": topicos.portavel(t.cwd),
            "session_host": HOST, "nome": t.name, "started": bool(t.started), "thread_id": thread_id}


def texto_saiu_do_telegram(t, thread_id: int, destino: str, onde_tg: str) -> str:
    if hosting.MODO == "pair":
        return (f"↪ <b>{html.escape(t.name)}</b> saiu do Telegram ({onde_tg}). "
                f"A conversa continua visível no app do Wisp, na seção Telegram.")
    como = (f"<code>claude --resume {t.session_id}</code> em "
            f"<code>{html.escape(topicos.portavel(t.cwd))}</code>")
    return f"↪ <b>{html.escape(t.name)}</b> saiu do Telegram ({onde_tg}). No terminal do {_host_nome(destino)}: {como}"


async def compartilhar_conversa(bot, sid: str, cwd: str, nome: str, conversation: str = "") -> dict:
    nome = nome.strip()
    if conversation and not ID_CONVERSA.match(conversation):
        raise ValueError("compartilhar recebeu um id de conversa invalido")
    if not sessao.valido(sid) or not nome:
        raise ValueError("compartilhar precisa de session_id valido e nome")
    chat_id = _chat_principal()
    if not chat_id:
        raise ValueError("telegram.chat_id ausente: nao sei em que chat abrir o topico")
    async with _vincular_lock:
        for t in store.all():
            if t.session_id == sid or (conversation and t.conversation == conversation):
                raise ValueError(f"essa conversa ja esta no Telegram (topico {_thread_de(t.key)})")
        cwd = os.path.expanduser(cwd or DEFAULT_CWD)
        if not os.path.isdir(cwd):
            log.warning("cwd %s nao existe aqui; compartilhando em %s", cwd, DEFAULT_CWD)
            cwd = DEFAULT_CWD
        ft = await bot.create_forum_topic(chat_id=chat_id, name=nome[:128])
        tid = ft.message_thread_id
        key = f"{chat_id}:{tid}"
        store.get_or_create(key, name=nome, cwd=cwd)
        existe = compartilhar.jsonl_path(sid, cwd).exists() or sessao.achar_local(sid) is not None
        agora = time.time()
        store.seguir_sessao(key, sid, existe, born=agora, last_used=agora)
        if conversation:
            store.set_conversation(key, conversation)
        store.set_meta(key, **{conversa.CURSOR: transcript_stamp()})
        conversa.garantir(store, transcripts, key, "new")
        topicos.garantir(key, nome, cwd, "Conversa compartilhada do app Wisp.")
        topicos.set_campos(key, onde="telegram")
        topicos.gravar_ponteiro(HOST, key, sid, existe, agora, agora, sessao.tamanho_local(sid), cwd)
        topicos.push_logo()
    chat = SimpleNamespace(id=chat_id)
    await send(bot, chat, tid, f"<b>{html.escape(nome)}</b>\ncwd: <code>{html.escape(cwd)}</code>\n\n"
                               "↩ conversa do app, continua aqui")
    for papel, texto in compartilhar.recap(sid, cwd):
        await send(bot, chat, tid, "💻 " + html.escape(texto) if papel == "user" else texto)
    return {"ok": True, "thread_id": tid, "name": nome, "session_id": sid}


async def _ctl_compartilhar(bot, op: dict) -> dict:
    return await compartilhar_conversa(bot, str(op.get("session_id") or ""), str(op.get("cwd") or ""),
                                       str(op.get("nome") or ""), str(op.get("conversation") or ""))


async def cmd_puxar(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorized(update):
        return
    _, thread_id = topic_key(update)
    if update.effective_chat.type != "supergroup":
        await reply(update, "tópicos só existem em supergrupo com <b>Topics</b> ligado.", thread_id)
        return
    try:
        lista = compartilhar.recentes(_CFG.conversations_file, {t.session_id for t in store.all()})
    except ValueError as e:
        await reply(update, html.escape(str(e)), thread_id)
        return
    if not lista:
        await reply(update, "todas as conversas recentes do app já estão no Telegram.", thread_id)
        return
    botoes = [[InlineKeyboardButton(f"{c['title'][:40]} · {compartilhar.relativa(c['updated'])}",
                                    callback_data=f"puxar:{c['session_id']}")] for c in lista]
    await update.effective_message.reply_text("Qual conversa do app trago pra cá?",
                                              reply_markup=InlineKeyboardMarkup(botoes),
                                              message_thread_id=thread_id)


async def on_puxar_botao(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    q = update.callback_query
    if not authorized(update) or not q or not (q.data or "").startswith("puxar:"):
        return
    sid = q.data.split(":", 1)[1]
    try:
        lista = compartilhar.recentes(_CFG.conversations_file, set(), n=10**6)
        c = next((c for c in lista if c["session_id"] == sid), None)
        if c is None:
            raise ValueError("essa conversa não está mais na lista do app")
        d = await compartilhar_conversa(ctx.bot, sid, c["cwd"], c["title"])
    except Exception as e:
        await q.answer(str(e)[:190], show_alert=True)
        return
    await q.answer("pronto")
    await q.edit_message_text(f"✅ trouxe «{d['name']}» pro tópico {d['thread_id']}")


async def _ctl_encerrar(bot, thread) -> dict:
    key = _key_da_thread(thread)
    if not key or not _thread_de(key):
        raise ValueError(f"topico {thread} desconhecido (ou e o Geral)")
    if store.get(key) is None:
        m = topicos.meta(key) or {}
        if m.get("status") in ("terminal", "encerrado"):
            if m.get("status") == "terminal":
                topicos.set_status(key, "encerrado")
                topicos.push_logo()
            return {"ok": True, "nome": m.get("name", ""), "thread_id": int(thread)}
        raise ValueError(f"topico {thread} nao esta no Telegram nem no terminal")
    chat_id, thread_id = int(key.rsplit(":", 1)[0]), _thread_de(key)
    nome = store.get(key).name
    await fechar(bot, chat_id, thread_id, key)
    if store.get(key) is not None:
        raise ValueError("o resumo falhou, entao o topico ficou")
    return {"ok": True, "nome": nome, "thread_id": thread_id}


async def _ctl_vincular(bot, op: dict) -> dict:
    sid, nome = str(op.get("session_id") or ""), str(op.get("nome") or "").strip()
    if not sessao.valido(sid) or not nome:
        raise ValueError("vincular precisa de session_id valido e nome")
    async with _vincular_lock:
        key = _espelho_de(sid)
        if key:
            return {"ok": True, "thread_id": _thread_de(key), "chat": int(key.rsplit(":", 1)[0])}
        chat_id = _chat_principal()
        if not chat_id:
            raise ValueError("sem chat configurado")
        ft = await bot.create_forum_topic(chat_id=chat_id, name=nome[:128])
        tid = ft.message_thread_id
        key = f"{chat_id}:{tid}"
        cwd_esp = str(op.get("cwd") or DEFAULT_CWD)
        store.get_or_create(key, name=nome, cwd=cwd_esp, meta={"espelho": sid})
        topicos.garantir(key, nome, cwd_esp, "Espelho da sessão do terminal no Telegram.")
        await send(bot, SimpleNamespace(id=chat_id), tid,
                   f"👀 vigiando a sessão do terminal: <b>{html.escape(nome)}</b>")
        return {"ok": True, "thread_id": tid, "chat": chat_id}


async def _alcancar_topico(bot, key: str) -> int:
    chat = SimpleNamespace(id=int(key.rsplit(":", 1)[0]))
    thread_id = _thread_de(key) or None

    async def enviar(texto: str) -> None:
        await send(bot, chat, thread_id, texto)
    return await conversa.alcancar(store, transcripts, key, enviar)


async def _alcancar_todos(bot) -> None:
    for t in store.all():
        try:
            if not t.conversation:
                conversa.garantir(store, transcripts, t.key)
            await _alcancar_topico(bot, t.key)
        except Exception as e:
            log.warning("alcance do topico %s falhou: %s", t.key, e)


async def _ctl_postar(bot, op: dict) -> dict:
    app_bot = bot
    reply_txt = str(op.get("reply") or "").strip()
    texto = str(op.get("texto") or "").strip()
    if not texto and not reply_txt and not op.get("conversation"):
        raise ValueError("texto vazio")
    if op.get("conversation"):
        key = _key_da_thread(op.get("thread"))
        topico = store.get(key) if key else None
        if topico is not None and topico.conversation == str(op["conversation"]):
            chat_id, tid = int(key.rsplit(":", 1)[0]), _thread_de(key)
            postadas = await _alcancar_topico(app_bot, key)
            arquivos = arquivos_validos(op["arquivos"]) if op.get("arquivos") else []
            await _postar_arquivos(app_bot, chat_id, tid or None, arquivos, None)
            visto = conversa.coberto(transcripts.conversation_entries(topico.conversation),
                                     str(store.get(key).meta.get(conversa.CURSOR) or ""), reply_txt,
                                     str(op.get("turn_at") or ""))
            if postadas or visto or not reply_txt:
                return {"ok": True, "thread_id": tid}
            user = str(op.get("user") or "").strip()
            chat = SimpleNamespace(id=chat_id)
            if user:
                await send(app_bot, chat, tid, "💻 " + html.escape(user))
            await send(app_bot, chat, tid, reply_txt)
            return {"ok": True, "thread_id": tid}
    if op.get("chat") not in (None, ""):
        chat_id, tid = int(op["chat"]), int(op.get("thread"))
    else:
        key = _key_da_thread(op.get("thread"))
        if not key:
            raise ValueError(f"topico {op.get('thread')} desconhecido")
        chat_id, tid = int(key.rsplit(":", 1)[0]), _thread_de(key)
    chat = SimpleNamespace(id=chat_id)
    arquivos = arquivos_validos(op["arquivos"]) if op.get("arquivos") else []
    if reply_txt:
        user = str(op.get("user") or "").strip()
        if user:
            await send(bot, chat, tid, "💻 " + html.escape(user))
        await _postar_arquivos(bot, chat_id, tid or None, arquivos, None)
        await send(bot, chat, tid, reply_txt)
    else:
        await send(bot, chat, tid, texto)
        await _postar_arquivos(bot, chat_id, tid or None, arquivos, None)
    return {"ok": True, "thread_id": tid}


ENVIAR_DEDUP_S = 600.0
_enviados_recentes: dict[tuple, float] = {}


async def _ctl_enviar(bot, op: dict) -> dict:
    try:
        thread = int(op.get("thread"))
    except (TypeError, ValueError):
        raise ValueError("thread invalida") from None
    key = _key_da_thread(thread)
    if not key:
        raise ValueError(f"topico {thread} desconhecido")
    itens = arquivos_validos(op.get("arquivos"))
    legenda = str(op.get("legenda") or "").strip() or None
    agora = time.monotonic()
    for k, quando in list(_enviados_recentes.items()):
        if agora - quando > ENVIAR_DEDUP_S:
            del _enviados_recentes[k]
    marca = (thread, tuple(str(p) for p, _ in itens), legenda)
    if marca in _enviados_recentes:
        log.info("enviar: pedido repetido no topico %s ignorado", thread)
        return {"ok": True, "enviados": 0, "repetido": True}
    _enviados_recentes[marca] = agora
    try:
        await _postar_arquivos(bot, int(key.rsplit(":", 1)[0]), _thread_de(key) or None, itens, legenda)
    except BaseException:
        _enviados_recentes.pop(marca, None)
        raise
    log.info("enviar: %d arquivo(s) no topico %s: %s", len(itens), thread, ", ".join(p.name for p, _ in itens))
    return {"ok": True, "enviados": len(itens)}


async def _ctl_desvincular(bot, op: dict) -> dict:
    sid = str(op.get("session_id") or "")
    key = _espelho_de(sid)
    if not key:
        raise ValueError(f"nenhum espelho para a sessao {sid[:8]}")
    await send(bot, SimpleNamespace(id=int(key.rsplit(":", 1)[0])), _thread_de(key), "vigia encerrado")
    _marcar_espelho(key, None)
    return {"ok": True, "thread_id": _thread_de(key)}


async def ctl_executar(app, op: dict, origem: str) -> None:
    id_ = str(op.get("id", ""))
    if not ctl._ID.match(id_):
        log.warning("ctl: id invalido ignorado: %r", id_[:80])
        return
    try:
        nome = op.get("op")
        if ctl.expirado(op):
            raise ValueError("pedido expirado")
        if nome == "encerrar":
            res = await _ctl_encerrar(app.bot, op.get("thread"))
        elif nome == "soltar":
            key = _key_da_thread(op.get("thread"))
            if not key:
                raise ValueError(f"topico {op.get('thread')} desconhecido")
            res = await soltar_topico(app.bot, int(key.rsplit(":", 1)[0]), _thread_de(key),
                                      key, op.get("destino", ""))
        elif nome == "compartilhar":
            res = await _ctl_compartilhar(app.bot, op)
        elif nome == "vincular":
            res = await _ctl_vincular(app.bot, op)
        elif nome == "postar":
            res = await _ctl_postar(app.bot, op)
        elif nome == "enviar":
            res = await _ctl_enviar(app.bot, op)
        elif nome == "desvincular":
            res = await _ctl_desvincular(app.bot, op)
        else:
            raise ValueError(f"op desconhecida: {nome!r}")
    except Exception as e:
        log.warning("ctl %s (%s) falhou: %s", id_, op.get("op"), e)
        res = {"ok": False, "erro": str(e)}
    try:
        if origem == "pc":
            await asyncio.to_thread(ctl.escrever_done_pc, id_, res)
        else:
            ctl.gravar_done(id_, res)
    except Exception as e:
        log.warning("ctl %s: nao gravei o resultado: %s", id_, e)


async def cmd_terminal(update: Update, ctx: ContextTypes.DEFAULT_TYPE, destino: str) -> None:
    key, thread_id = topic_key(update)
    chat_id = update.effective_chat.id
    if not thread_id or store.get(key) is None:
        await reply(update, "isso só vale dentro de um tópico com sessão.", thread_id)
        return
    if destino not in ctl.destinos():
        await reply(update, f"aqui há uma máquina só: diga <code>terminal</code> e a sessão vai para o terminal "
                            f"do {_host_nome(HOST)}.", thread_id)
        return
    await reply(update, f"soltando para o terminal do {_host_nome(destino)}"
                        + (" assim que o turno atual acabar…" if lock_for(key).locked() else "…"), thread_id)

    async def _vai():
        try:
            await soltar_topico(ctx.bot, chat_id, thread_id, key, destino)
        except Exception as e:
            log.warning("soltar %s falhou: %s", key, e)
            await send(ctx.bot, SimpleNamespace(id=chat_id), thread_id,
                       f"não consegui soltar: <code>{html.escape(str(e))}</code>")
    asyncio.create_task(_vai())


PC_TICK_S = 30.0
PC_RAPIDO_S = 5.0
PC_RAPIDO_JANELA_S = 120.0
PC_FALHA_S = 20.0
ESPELHO_S = 60.0


def _candidatas_pelas_notas() -> dict[str, str]:
    out = {}
    for m in topicos.abertos():
        sid = m.get("session_id", "")
        if m.get("session_host") == "pc" and m.get("session_started") == "true" and sessao.valido(sid):
            cwd = os.path.expanduser(m.get("cwd") or DEFAULT_CWD)
            out[sid] = cwd if os.path.isdir(cwd) else DEFAULT_CWD
    return out


def candidatas_espelho() -> dict[str, str]:
    lido = sessao.topicos_no_pc()
    if lido is None:
        log.info("espelho: topics.json do PC ilegivel; usando as notas")
        return _candidatas_pelas_notas()
    home_pc, topicos_pc = lido
    out = {}
    for key, sid, cwd_pc in topicos_pc:
        t = store.get(key)
        out[sid] = sessao.cwd_espelho(cwd_pc, home_pc, str(Path.home()), os.path.isdir,
                                      t.cwd if t else "", DEFAULT_CWD)
    return out


async def _espelhar() -> int:
    cand = await asyncio.to_thread(candidatas_espelho)
    if not cand:
        return 0
    metas = {t.session_id: topicos.meta(t.key) for t in store.all() if t.session_id in cand}
    return await asyncio.to_thread(sessao.espelhar_do_pc, cand, metas)


async def _empurrar_sessao(ped: dict, em_voo: set, falhas: dict) -> None:
    sid = str(ped.get("session_id", ""))
    try:
        if ctl.expirado(ped):
            log.info("pedido de sessao %s expirado; descartado", sid)
        elif sessao.valido(sid):
            await asyncio.to_thread(sessao.enviar_ao_pc, sid, ped.get("cwd_pc") or "~")
        await asyncio.to_thread(ctl.apagar_pedido_pc, sid)
        falhas.pop(sid, None)
    except Exception as e:
        falhas[sid] = falhas.get(sid, 0) + 1
        log.warning("empurrar sessao %s ao PC falhou (%d): %s", sid, falhas[sid], e)
        if falhas[sid] >= 3:
            falhas.pop(sid, None)
            await asyncio.to_thread(ctl.apagar_pedido_pc, sid)
    finally:
        em_voo.discard(sid)


async def _drenar_pc(app, ativo: bool, em_voo: set, falhas: dict) -> tuple[bool, bool]:
    try:
        ops, peds, ok = await asyncio.to_thread(ctl.drenar_pc, ativo, True)
        for p in ops:
            _disparar(ctl_executar(app, p, "pc"))
        for ped in peds:
            sid = str(ped.get("session_id", ""))
            if sid not in em_voo:
                em_voo.add(sid)
                asyncio.create_task(_empurrar_sessao(ped, em_voo, falhas))
        return bool(ops or peds), ok
    except Exception as e:
        log.warning("drenar PC falhou: %s", e)
        return False, False


async def controlador(app) -> None:
    proximo_pc, rapido_ate, ciclos = 0.0, 0.0, 0
    drenando: asyncio.Task | None = None
    espelhando: asyncio.Task | None = None
    proximo_espelho = 0.0
    em_voo: set[str] = set()
    falhas: dict[str, int] = {}
    resolvendo: asyncio.Task | None = None
    alcancando: asyncio.Task | None = None
    proximo_alcance = 0.0
    while True:
        await asyncio.sleep(2)
        try:
            h = app.bot_data.get("hosting")
            ativo = bool(h and h.ativo)
            if ativo:
                for p in ctl.pendentes():
                    ctl.consumir(p)
                    _disparar(ctl_executar(app, p, "local"))
            agora = time.time()
            if drenando is not None and drenando.done():
                achou, ok = drenando.result()
                drenando = None
                if achou:
                    rapido_ate = agora + PC_RAPIDO_JANELA_S
                proximo_pc = agora + (PC_FALHA_S if not ok else
                                      PC_RAPIDO_S if agora < rapido_ate else PC_TICK_S)
            if (hosting.MODO == "pair" and HOST == "mac" and h is not None and drenando is None and agora >= proximo_pc
                    and h.pc_estado != "offline"):
                drenando = asyncio.create_task(_drenar_pc(app, ativo, em_voo, falhas))
            if espelhando is not None and espelhando.done():
                if espelhando.exception():
                    log.warning("espelho do PC falhou: %s", espelhando.exception())
                elif espelhando.result():
                    log.info("espelho: %d sessao(oes) copiadas do PC", espelhando.result())
                espelhando = None
            if (hosting.MODO == "pair" and HOST == "mac" and h is not None and espelhando is None and agora >= proximo_espelho
                    and h.pc_estado == "active"):
                proximo_espelho = agora + ESPELHO_S
                espelhando = asyncio.create_task(_espelhar())
            if alcancando is not None and alcancando.done():
                alcancando = None
            if ativo and alcancando is None and agora >= proximo_alcance:
                proximo_alcance = agora + ALCANCE_S
                alcancando = asyncio.create_task(_alcancar_todos(app.bot))
            if resolvendo is not None and resolvendo.done():
                if not resolvendo.cancelled() and resolvendo.exception():
                    log.warning("em-voo falhou: %s", resolvendo.exception())
                resolvendo = None
            if resolvendo is None and any(e["fim"] for e in _em_voo_mac.values()):
                resolvendo = asyncio.create_task(_resolver_em_voo())
            ciclos += 1
            if ciclos % 1800 == 0:
                ctl.limpar()
        except Exception as e:
            log.warning("controlador falhou: %s", e)


def main() -> int:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    for noisy in ("httpx", "httpcore", "telegram.ext.Updater"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
    try:
        cfg = load_bot_config()
    except ConfigError as e:
        print(e, file=sys.stderr)
        return 2
    token = cfg.token

    app = (Application.builder()
           .bot(polling.criar_bot(token))
           .concurrent_updates(True)
           .build())
    app.add_handler(CommandHandler("novo", _contado(cmd_novo)))
    app.add_handler(CommandHandler("fim", _contado(cmd_fim)))
    app.add_handler(CommandHandler("chatid", _contado(cmd_chatid)))
    app.add_handler(CommandHandler("status", _contado(cmd_status)))
    app.add_handler(CommandHandler("reset", _contado(cmd_reset)))
    app.add_handler(CommandHandler("clear", _contado(cmd_reset)))
    app.add_handler(CommandHandler("cwd", _contado(cmd_cwd)))
    app.add_handler(CommandHandler("puxar", _contado(cmd_puxar)))
    app.add_handler(CallbackQueryHandler(_contado(on_puxar_botao), pattern=r"^puxar:"))
    app.add_handler(CallbackQueryHandler(on_aprovacao, pattern=r"^aprov:"))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, _contado(on_message)))
    app.add_handler(MessageHandler(filters.Document.ALL | filters.PHOTO | filters.VIDEO | filters.VIDEO_NOTE, _contado(on_attachment)))
    app.add_handler(MessageHandler(filters.COMMAND, _contado(on_passthrough)))
    log.info("wisp-bot no ar · host=%s · hosting=%s · modelo=%s · cwd=%s", HOST, hosting.MODO, MODELO, DEFAULT_CWD)
    asyncio.run(_viver(app))
    return 0


def _turno_rodando() -> bool:
    return (_em_curso > 0 or bool(_anexos_pendentes) or any(n > 0 for n in _turnos_mac.values())
            or any(lk.locked() for lk in _locks.values()))


async def _viver(app) -> None:
    parar = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, parar.set)
    async with app:
        await app.start()
        await _post_init(app)
        h = hosting.Hosting(app, lambda m: _ao_ativar(app, m), lambda m: _ao_desativar(app, m),
                            passar_sessoes, ocupado=_turno_rodando,
                            antes_de_soltar=lambda: topicos.push_agora(hosting.HANDOVER_PC_S))
        app.bot_data["hosting"] = h
        polling.vigiar(lambda: h.ativo)
        vida = asyncio.create_task(h.rodar())

        async def _avisar_geral(texto: str) -> None:
            await app.bot.send_message(_chat_principal(), texto)
        canario = asyncio.create_task(saude.vigiar(_avisar_geral, parar))
        colhedor = asyncio.create_task(colheita.vigiar(parar))
        await asyncio.wait([vida, asyncio.create_task(parar.wait())],
                           return_when=asyncio.FIRST_COMPLETED)
        canario.cancel()
        colhedor.cancel()
        if vida.done() and vida.exception():
            log.error("hosting morreu: %r", vida.exception())
        vida.cancel()
        if app.updater.running:
            await app.updater.stop()
        try:
            await asyncio.wait_for(topicos.push_agora(), timeout=15)
        except asyncio.TimeoutError:
            log.warning("push da saida nao terminou em 15s")
        hosting.gravar_estado("off")
        await app.stop()


if __name__ == "__main__":
    raise SystemExit(main())
