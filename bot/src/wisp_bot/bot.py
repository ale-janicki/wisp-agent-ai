"""O bot do Telegram: Geral respondendo, com sessao por topico.

Regra que sustenta a arquitetura: nenhum turno do Geral bloqueia o bot.
Cada topico tem sua propria trava; topicos diferentes rodam em paralelo.
"""
from __future__ import annotations
import asyncio, functools, html, json, logging, os, re, signal, sys, time
from types import SimpleNamespace
from pathlib import Path

from telegram import Update, BotCommandScopeAllGroupChats, BotCommandScopeAllPrivateChats
from telegram.constants import ChatAction, ParseMode
from telegram.error import BadRequest, NetworkError
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes

from .store import Store
from .claude_runner import run as claude_run, strip_status
from . import abrir as abrir_mod
from . import ctl
from . import sessao
from . import topicos
from . import tg_html
from . import hosting, saude, vigilia, polling
from . import vigia as vigia_mod
from .config import CURRENT as _CFG, ConfigError, load_bot_config
from .hosting import HOST

log = logging.getLogger("wisp")

# Tudo do usuario vem do wisp.json (config.py): user_id 0 ou chat vazio = ninguem passa.
ALLOWED_USER_ID = _CFG.user_id
# Trava tambem por grupo: o bot e publico e qualquer um pode adiciona-lo a um grupo.
ALLOWED_CHAT_IDS = set(_CFG.chat_ids)
DEFAULT_CWD = str(_CFG.brain)
PERSONA = _CFG.persona
_QUEM = f"o {_CFG.user_name}" if _CFG.user_name else "o usuario"
TG_LIMIT = 4000          # o teto real e 4096; a folga cobre a tag de fechamento
# Opus no Geral e nos topicos (decisao de 28/09): e ele que segura a linha
# de raciocinio e julga operator/reviewer.
MODELO = os.environ.get("WISP_MODEL", "opus")

# Atalhos de repo para o /novo. Sem isto o usuario digitaria o caminho inteiro no celular,
# que e onde digitar caminho e mais caro.
REPOS_ROOT = os.path.expanduser(os.environ.get("WISP_REPOS_ROOT", "~/repos"))
ATALHOS = {"brain": DEFAULT_CWD}

# 🔑 O Geral conversa e ABRE TOPICOS (decisao de 28/09). Tarefa de verdade
# nao roda aqui: vira um topico com agente proprio, e o usuario continua a conversa la.
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

# 🔑 Topico = terminal com Opus de manager (decisao de 28/09). A sessao vive
# ate "encerrado", segura o plano e o contexto; o rapido faz direto, a execucao
# maior vai para operator. /comando do usuario roda como no terminal (decisao 01/10).
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

# Primeiro turno de uma sessao nova num topico que ja tem historia — em outra
# maquina, ou antes de um /reset. A sessao nao viaja; a nota do brain sim.
# O bot confere o "Onde está" depois do turno (nada mais o garante): se o turno
# fechou sem reescrever a secao, o bot manda fazer agora, na mesma sessao.
FORCA_ONDE_ESTA = """[regra do topico] O turno anterior fechou sem reescrever a secao
`## Onde está` de {nota}. Reescreva agora (3-8 linhas: o que esta feito, o que esta
sujo no disco e onde, o proximo passo). Nao mexa no Log nem no frontmatter.
Responda so "ok"."""

# Sessao local ja existe, mas o ultimo turno foi em OUTRA maquina: a sessao daqui
# esta atrasada. Sem isto o PC volta e responde como se o turno do Mac nao existisse.
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

# O Geral recicla uma vez por dia (decisao de 28/09): a sessao que passou de
# GERAL_HOURS de idade e zerada no proximo turno — mas so depois de uma pausa,
# para nao cortar uma conversa em andamento. Topicos nunca reciclam sozinhos.
GERAL_HOURS = float(os.environ.get("WISP_GERAL_HOURS", "24"))
PAUSE_MIN = float(os.environ.get("WISP_PAUSE_MIN", "30"))
# 3600 = mesmo teto dos topicos (decisao de 28/10): 300s matava respostas boas
# no meio; o teto fica so como trava contra turno travado.
GERAL_TIMEOUT = int(os.environ.get("WISP_GERAL_TIMEOUT", "3600"))
TOPICO_TIMEOUT = int(os.environ.get("WISP_TOPICO_TIMEOUT", "3600"))
# 0 = o "trabalhando" sai na hora (decisao de 21/10): o turno minimo do Opus ja
# leva ~8s (medido), e sem sinal imediato parece que a mensagem nao chegou.
PROGRESSO_S = float(os.environ.get("WISP_PROGRESSO_S", "0"))
# "terminal" / "puxa pro terminal" / "continua no terminal" [mac|pc]: leva o topico para o terminal
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


_em_curso = 0    # handlers do Telegram e tarefas disparadas (pedidos da fila, anexos, turnos soltos) ainda vivos


def _contado(fn):
    """Handler do PTB que conta em _em_curso enquanto roda: o update ja lido e ainda sem turno segura o PC."""
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
    """create_task que conta em _em_curso desde o disparo (antes de a task rodar) ate ela acabar."""
    global _em_curso
    _em_curso += 1
    t = asyncio.get_running_loop().create_task(coro)

    def _fim(_t) -> None:
        global _em_curso
        _em_curso -= 1
    t.add_done_callback(_fim)
    return t


def lock_for(key: str) -> asyncio.Lock:
    """Uma trava por topico: dois Claudes no mesmo cwd se atropelam."""
    if key not in _locks:
        _locks[key] = asyncio.Lock()
    return _locks[key]


def topic_key(update: Update) -> tuple[str, int | None]:
    chat_id = update.effective_chat.id
    thread_id = getattr(update.effective_message, "message_thread_id", None)
    return f"{chat_id}:{thread_id or 0}", thread_id


async def keep_typing(bot, chat_id: int, thread_id: int | None, parar: asyncio.Event) -> None:
    """O 'digitando' do Telegram expira em ~5s, e um turno do Claude leva bem mais.
    Sem reenviar, o indicador some e a conversa parece morta. Reenvia ate o fim."""
    while not parar.is_set():
        try:
            await bot.send_chat_action(chat_id, ChatAction.TYPING, message_thread_id=thread_id)
        except Exception as e:         # cosmetico: nunca derruba o turno, mas nao some calado
            log.warning("typing falhou em %s/%s: %s", chat_id, thread_id, e)
        try:
            await asyncio.wait_for(parar.wait(), timeout=4.0)
        except asyncio.TimeoutError:
            pass


async def progresso(bot, chat_id: int, thread_id: int | None, parar: asyncio.Event,
                    atividade: list[str] | None = None) -> None:
    """Mensagem visivel de "trabalhando", porque o 'digitando' sozinho nao bastou: em
    28/09 um turno de 7 min pareceu bot parado. Aparece so se o turno passar de
    PROGRESSO_S, mostra tempo + o que o Claude faz agora (`atividade[0]`, escrita
    pelo on_event) e some quando a resposta chega. A mensagem vai sem parse_mode,
    entao a atividade segue como texto puro."""
    try:
        await asyncio.wait_for(parar.wait(), timeout=PROGRESSO_S)
        return                                    # rapido: nao polui o chat
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
                pass                              # limite de edicao: tenta no proximo ciclo
    try:
        await msg.delete()
        log.info("progresso apagado em %s/%s", chat_id, thread_id)
    except Exception as e:
        log.warning("progresso nao apagou em %s/%s: %s", chat_id, thread_id, e)


async def send(bot, chat, thread_id: int | None, text: str) -> None:
    """HTML limpo e balanceado por pedaco (tg_html). Se ainda assim o Telegram
    recusar, vai texto puro — sem tags e SEM escapar: o fallback antigo fazia
    html.escape e o usuario via `&lt;b&gt;` literal (30/09)."""
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
    """Silencio para quem nao passa: responder ja confirmaria que ha alguem atras do bot."""
    u = update.effective_user
    if not u or u.id != ALLOWED_USER_ID:
        return False
    if ALLOWED_CHAT_IDS and str(update.effective_chat.id) not in ALLOWED_CHAT_IDS:
        return False
    return True


async def cmd_chatid(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    """Descobre o id do grupo para travar em telegram.chat_id. So responde ao dono."""
    u = update.effective_user
    if not u or u.id != ALLOWED_USER_ID:
        return
    _, thread_id = topic_key(update)
    await reply(update, f"chat_id: <code>{update.effective_chat.id}</code>\n"
                        f"thread_id: <code>{thread_id or 0}</code>", thread_id)


def is_geral(key: str) -> bool:
    return key.endswith(":0")


def reset_due(topic) -> str | None:
    """Motivo do reset, ou None. Silencioso no chat; vai para o log do servico.

    So o Geral recicla: sessao com mais de GERAL_HOURS e pelo menos PAUSE_MIN
    parada. Topico nunca — ele so acaba no "encerrado"/fim."""
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
            ("chatid", "ids do chat e do tópico")]


def comandos_claude() -> dict[str, str]:
    """Comandos e skills do Claude no PC: {nome: descricao}. Lido na hora, entao
    comando novo sincronizado pelo brain aparece sem reiniciar o bot."""
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
    """Skills e comandos dos plugins instalados, com o nome que o terminal usa
    (`/plugin:skill`)."""
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
    """Telegram so aceita [a-z0-9_] em comando: '-' e ':' viram '_'."""
    return re.sub(r"[-:]", "_", nome).lower()


def mapa_tg(conhecidos: dict[str, str]) -> dict[str, str]:
    """{nome no Telegram: nome real}. Passou de 32 chars (limite do Telegram), o
    plugin cai fora: superpowers:test-driven-development -> test_driven_development,
    se nao colidir com outro. Ainda longo ou colidindo: fica fora do menu."""
    mapa: dict[str, str] = {}
    for n in sorted(conhecidos, key=lambda n: ":" in n):   # nativos primeiro
        tg = nome_tg(n)
        if len(tg) > 32 and ":" in n:
            tg = nome_tg(n.split(":", 1)[1])
        if re.fullmatch(r"[a-z0-9_]{1,32}", tg) and tg not in mapa and tg not in dict(PROPRIOS):
            mapa[tg] = n
    return mapa


def comando_claude(msg: str) -> str:
    """/superpowers_brainstorming@bot args -> /superpowers:brainstorming args. O menu
    usa o nome do Telegram e aqui volta ao nome real."""
    cab, _, resto = msg.partition(" ")
    nome = cab[1:].split("@", 1)[0]
    conhecidos = comandos_claude()
    if nome not in conhecidos:
        nome = mapa_tg(conhecidos).get(nome, nome)
    return f"/{nome} {resto}".strip()


# o menu e atalho; qualquer /comando continua indo pro Claude pelo passthrough
# (comando_claude). No celular, tocar no menu ENVIA o comando na hora, sem deixar
# digitar nada depois (21/10): entra so o que roda sem argumento.
# /novo e qualquer outro comando continuam funcionando digitados.
MENU = ["diagnose", "status", "reset", "cwd", "fim"]


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
    """Sessao local do topico. Sem sessao aqui, nome e cwd vem da nota do brain —
    e assim que um topico aberto no PC continua no Mac e vice-versa."""
    t = store.get(key)
    if t:
        return t
    tid = key.split(":")[1]
    m = topicos.meta(key) or {}
    nome = m.get("name") or ("Geral" if tid == "0" else f"tópico {tid}")
    cwd = os.path.expanduser(m.get("cwd") or DEFAULT_CWD)
    return store.get_or_create(key, nome, cwd if os.path.isdir(cwd) else DEFAULT_CWD)


def nota_do_topico(key: str, t) -> str:
    """Garante a nota e devolve o caminho relativo ao brain."""
    return topicos.rel(topicos.garantir(key, t.name, t.cwd))


def contexto_resposta(m) -> str:
    return _contexto_citacao(m)


def _contexto_citacao(m) -> str:
    """Resposta do Telegram ("responder" em cima de uma mensagem) vira contexto do
    turno — sem isto o Claude recebe so o texto novo e nao sabe a que ele se refere.
    Em topico de forum, toda mensagem "responde" a de criacao do topico: essa nao conta."""
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
    """O ponteiro de sessao do topico vive no sessoes-<HOST>.json (so este host escreve, a nota nao
    conflita): qualquer host que assuma retoma a mesma. O host da entrada = onde esta o jsonl mais novo;
    session_size deixa o outro host ver se a copia dele esta defasada."""
    t = store.get(key)
    if not t:
        return
    topicos.gravar_ponteiro(HOST, key, t.session_id, bool(t.started), t.born, t.last_used,
                            sessao.tamanho_local(t.session_id), t.cwd)


def gravar_sessao_seguro(key: str) -> None:
    """gravar_sessao que nunca derruba quem chama: a nota falhar nao pode engolir a resposta."""
    try:
        gravar_sessao(key)
    except Exception as e:
        log.warning("gravar_sessao de %s falhou: %s", key, e)


async def alinhar_sessao(key: str, topic):
    """Antes do turno: se a nota aponta outra sessao (ou outra maquina tem a copia mais nova),
    traz o jsonl para ca e adota. Devolve (topico, segue): segue=False = a nota nao confirma a
    sessao local (falhou ou nota antiga) e o turno cai no CONTINUACAO/RETORNO."""
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


HANDOVER_S = 20.0             # o PC espera GRACE_S=25s pelo "peer-yielded"; as sessoes tem que caber


_em_voo_mac: dict[str, dict] = {}   # Mac: key -> {sid, cwd, ts, fim, enviado, falhas, prox}; turnos em voo na cessao
_turnos_mac: dict[str, int] = {}    # key -> turnos neste processo (segurando o lock ou na fila)
EM_VOO_TENTATIVAS = 3
EM_VOO_ESPERA_RETRY_S = 10.0


def _marcador_em_voo() -> dict:
    return {k: {"sid": e["sid"], "ts": e["ts"]} for k, e in _em_voo_mac.items()}


async def marcar_em_voo() -> None:
    """Mac prestes a ceder: o turno que ainda segura o lock termina aqui, entao o PC nao pode
    retomar a copia que ele empurra agora. Grava o marcador no PC ANTES de ceder."""
    for t in store.all():
        if _turnos_mac.get(t.key, 0) <= 0:
            continue
        if t.key in _em_voo_mac:
            if not _em_voo_mac[t.key]["fim"]:
                _em_voo_mac[t.key]["ts"] = time.time()      # turno ainda rodando: a entrada nao expira
        else:
            _em_voo_mac[t.key] = {"sid": t.session_id, "cwd": t.cwd, "ts": time.time(), "fim": False,
                                  "enviado": False, "falhas": 0, "prox": 0.0}
    if _em_voo_mac:
        if await hosting.gravar_em_voo_pc(_marcador_em_voo()):
            log.info("handover: turno(s) em voo no Mac: %s", ", ".join(_em_voo_mac))
        else:
            log.warning("handover: marcador em-voo nao chegou ao PC")


async def passar_sessoes() -> None:
    """Mac prestes a ceder ao PC: marca os turnos em voo, manda as sessoes que so o Mac tem em dia
    e o brain (as notas), dentro de HANDOVER_S. O que nao couber o PC pede (pedir) no 1o turno."""
    await marcar_em_voo()
    cand = {t.session_id: t.cwd for t in store.all()
            if t.started and (topicos.meta(t.key) or {}).get("session_host") == HOST
            and t.key not in _em_voo_mac}              # copia parcial de turno em voo nao vai
    if not sessao.pendentes(cand):                 # standby sem nada novo: nao gasta o prazo do handover
        return
    tarefas = [topicos.push_agora(HANDOVER_S),
               asyncio.to_thread(sessao.empurrar_mudadas, cand, HANDOVER_S - 3)]
    try:
        await asyncio.wait_for(asyncio.gather(*tarefas, return_exceptions=True), HANDOVER_S)
    except asyncio.TimeoutError:
        log.warning("handover: passou de %ds; cedendo mesmo assim", int(HANDOVER_S))


def _fim_do_turno_mac(key: str) -> None:
    """O ultimo turno em voo acabou: o controlador empurra o jsonl inteiro e tira a marca do PC."""
    e = _em_voo_mac.get(key)
    if e:
        e["fim"], e["enviado"], e["falhas"], e["prox"] = True, False, 0, 0.0
        t = store.get(key)
        if t:
            e["sid"], e["cwd"] = t.session_id, t.cwd


async def _resolver_em_voo() -> None:
    """Empurra o jsonl e a nota dos turnos em voo que acabaram e reescreve o marcador sem eles. A chave
    so sai da lista depois que o marcador foi gravado; falhou, tenta de novo (espacado) ate o teto."""
    for key, e in list(_em_voo_mac.items()):
        if e.get("desistiu"):
            if time.time() - e["ts"] > 1800:       # o PC ja ignora a marca: sai daqui tambem
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
                    # sem o jsonl, soltar a marca faria o PC retomar a copia velha: ela fica no
                    # marcador ate expirar (o PC ignora depois de 30 min)
                    e["desistiu"] = True
                    log.error("em-voo %s: jsonl nao chegou ao PC; marca fica ate expirar", key)
                continue
            await topicos.push_agora()             # a nota (Log, session_*) tem que chegar antes da marca cair
            e["enviado"], e["falhas"] = True, 0
        if not e["fim"]:                           # turno novo comecou durante o envio: espera o fim dele
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
    """PC: o Mac ainda termina um turno deste topico. Espera (lock ja seguro) a marca sumir.
    True = esperou (a nota do Mac pode ter chegado depois do ultimo pull)."""
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
VIGIA_TICK_S = 60
_vincular_lock = asyncio.Lock()


def _e_espelho(key: str) -> bool:
    t = store.get(key)
    return bool(t and t.meta.get("espelho"))


def _espelho_de(session_id: str) -> str | None:
    """Key do topico espelho desta sessao do terminal."""
    return next((t.key for t in store.all() if t.meta.get("espelho") == session_id), None)


def _marcar_espelho(key: str, session_id: str | None) -> None:
    """Liga/desliga a marca de espelho no topico."""
    store.set_meta(key, espelho=session_id)


TERMINAL_RODANDO_AVISO = "a sessão está rodando no terminal agora; mando quando terminar."
TERMINAL_POLL_S = 10.0


def _escrita_bot(key: str) -> float:
    """Epoch da ultima escrita conhecida do bot (ou da adocao) no jsonl do topico; persiste em meta, sobrevive a restart."""
    t = store.get(key)
    try:
        return float((t.meta or {}).get("escrita_bot") or 0.0) if t else 0.0
    except (TypeError, ValueError):
        return 0.0


async def _esperar_terminal(bot, chat, thread_id: int | None, key: str) -> None:
    """Topico que assumiu a sessao do terminal (modo celular): nunca dois escritores no mesmo jsonl. Chamado com o
    lock do topico ja tomado, logo antes do turno do Claude. Se o terminal esta no meio de um turno (ou escreveu ha
    menos de 60 s), avisa uma vez e segura a mensagem ate ele acabar. Nao mata o processo do terminal."""
    t = store.get(key)
    sid = (t.meta or {}).get("celular") if t else None
    if not sid:
        return
    cwd, avisou = os.path.expanduser(t.cwd), False
    while await asyncio.to_thread(vigia_mod.terminal_ativo, sid, cwd, None, _escrita_bot(key)):
        if not avisou:
            avisou = True
            log.info("topico %s: terminal ativo na sessao %s; mensagem na fila", key, sid[:8])
            await send(bot, chat, thread_id, TERMINAL_RODANDO_AVISO)
        await asyncio.sleep(TERMINAL_POLL_S)


async def turno(bot, chat, thread_id: int | None, key: str, msg: str, contexto: str = "") -> None:
    """Um turno completo num topico (ver _turno); ao fim, se a cessao deixou este turno em voo no
    Mac, entrega o jsonl ao PC. A resposta do Mac segue para o Telegram mesmo sem ele estar lendo."""
    if _e_espelho(key):                            # 2o processo na mesma sessao = incidente de 23/10
        log.info("espelho %s: mensagem recusada, a sessao e do terminal", key)
        await send(bot, chat, thread_id, ESPELHO_AVISO)
        return
    sessao.contar_turno(_turnos_mac, key)          # antes do lock: o turno na fila tambem segura a marca
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
        if ultimo:                                 # turno na fila ainda precisa da vigilia: so o ultimo agenda
            vigilia.agendar_soltura(key, vigilia.SEGURA_GERAL_S if is_geral(key) else vigilia.SEGURA_TOPICO_S)
            _fim_do_turno_mac(key)


async def _turno(bot, chat, thread_id: int | None, key: str, msg: str, contexto: str = "") -> None:
    """Um turno completo num topico. Usado pelo on_message e pelo /novo, que
    precisa disparar a primeira instrucao sem bloquear o comando."""
    topic = topico_local(key)
    lk = lock_for(key)
    if sessao.avisar_fila(lk):                     # antes de qualquer coisa pegar o lock
        await send(bot, chat, thread_id, "⏳ ainda estou no turno anterior deste tópico. Entra na fila.")
    parar_a = asyncio.Event()                      # a espera do jsonl pode levar ate ESPERA_PEDIDO_S
    typing_a = asyncio.create_task(keep_typing(bot, chat.id, thread_id, parar_a))
    try:
        async with lk:                             # antes do reset: o Geral decide a idade pela sessao da nota
            if await _esperar_turno_do_mac(bot, chat, thread_id, key):
                try:
                    await topicos.pull()           # so apos esperar o Mac: traz a nota dele antes de alinhar
                except Exception as e:
                    log.warning("pull apos em-voo de %s falhou: %s", key, e)
            topic, segue = await alinhar_sessao(key, topic)
    except Exception as e:                         # cai no CONTINUACAO/RETORNO, como antes da nota mandar
        log.warning("alinhar_sessao de %s falhou: %s", key, e)
        topic, segue = topico_local(key), False
    finally:
        parar_a.set()
        await typing_a
    motivo = reset_due(topic)
    if motivo:
        log.info("reset automatico em %s: %s", key, motivo)
        store.reset(key)
        topic = store.get_or_create(key, topic.name, topic.cwd)

    nota = nota_do_topico(key, topic)
    if nota and motivo:
        gravar_sessao_seguro(key)                  # a sessao zerada aqui nao pode ser desfeita pela nota velha
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

    # topico de tarefa (nao Geral): o "Onde está" e obrigatorio
    exige = bool(nota) and not is_geral(key)
    nota_abs = str(topicos.BRAIN / nota) if exige else ""

    async with lk:
        await _esperar_terminal(bot, chat, thread_id, key)
        base = topicos.onde_esta_hash(key) if exige else ""
        env = {"WISP_TOPIC_NOTE": nota_abs, "WISP_TOPIC_BASE": base} if exige else {}
        if thread_id is not None:               # o puxar do proprio topico nao pode esperar este turno
            env["WISP_TOPIC_THREAD"] = str(thread_id)
        env = env or None
        parar = asyncio.Event()
        aviso_onde = ""
        typing = asyncio.create_task(keep_typing(bot, chat.id, thread_id, parar))
        atividade = [""]
        def on_event(rotulo: str) -> None:
            atividade[0] = rotulo
        async def on_text(texto: str) -> None:
            # parcial nao vira mensagem: em 21/10 foram 12+ narracoes num topico em 14 min.
            # A 1a linha vai para a mensagem "trabalhando"; so a resposta final e enviada.
            t = tg_html.plain(strip_status(texto)).strip()
            if len(t) >= 3:
                atividade[0] = "💬 " + t.split("\n", 1)[0][:120]
                log.info("parcial no progresso em %s/%s (%d chars)", chat.id, thread_id, len(t))
        prog = asyncio.create_task(progresso(bot, chat.id, thread_id, parar, atividade))
        try:
            # turno que falhou (ex.: OAuth expirado) deixa o jsonl sem mark_started:
            # --session-id nele daria "already in use" em toda mensagem seguinte
            existe = topic.started or sessao.achar_local(topic.session_id) is not None
            res = await claude_run(prompt, session_id=topic.session_id,
                                   cwd=topic.cwd, started=existe,
                                   model=MODELO,
                                   timeout=GERAL_TIMEOUT if is_geral(key) else TOPICO_TIMEOUT,
                                   extra_prompt=regra_para(key, chat.id, thread_id, nota),
                                   disallowed="",
                                   env=env, on_event=on_event, on_text=on_text)
            if not res.ok and "dormiu no meio" in res.text:      # uma retomada so, sem laco
                async def aviso_dormiu() -> None:
                    await send(bot, chat, thread_id, "💤 Mac fechado na bateria — rodo quando abrir.")
                await vigilia.esperar_poder(aviso_dormiu)
                existe = topic.started or sessao.achar_local(topic.session_id) is not None
                res = await claude_run("Continue de onde parou." if existe else prompt,
                                       session_id=topic.session_id,
                                       cwd=topic.cwd, started=existe, model=MODELO,
                                       timeout=GERAL_TIMEOUT if is_geral(key) else TOPICO_TIMEOUT,
                                       extra_prompt=regra_para(key, chat.id, thread_id, nota),
                                       disallowed="", env=env, on_event=on_event, on_text=on_text)
            if res.ok and exige and topicos.onde_esta_hash(key) == base:
                log.warning("Onde está nao atualizado em %s: forcando", key)
                f = await claude_run(FORCA_ONDE_ESTA.format(nota=nota_abs),
                                     session_id=topic.session_id, cwd=topic.cwd, started=True,
                                     model=MODELO, timeout=300, env=env)
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
            store.set_meta(key, escrita_bot=time.time())
        if res.ok:
            store.mark_started(key)
            store.bump(key, res.cost_usd)
            await send(bot, chat, thread_id, res.text)
        else:
            await send(bot, chat, thread_id, f"<b>falhou</b>\n<pre>{html.escape(res.text)}</pre>")
        if nota:
            try:
                topicos.anexar_log(key, HOST, msg, res.text, ok=res.ok)
                if res.ok:
                    gravar_sessao(key)
                topicos.push_logo()
            except Exception as e:                 # o log nunca derruba o turno
                log.warning("log do topico %s falhou: %s", key, e)


async def on_message(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorized(update):
        log.warning("ignorado: user_id=%s", getattr(update.effective_user, "id", None))
        return                                   # silencio proposital: nao confirma existencia
    msg = (update.effective_message.text or "").strip()
    if not msg:
        return

    await processa(update, ctx, msg, contexto_resposta(update.effective_message))


ANEXOS_DIR = hosting.DIR / "anexos"
ANEXO_JANELA = 3.0          # s: arquivos enviados juntos chegam como mensagens separadas
ANEXO_SEM_TEXTO = "(sem texto — veja o que é e me diga)"
ANEXO_FOTO = (".jpg", ".jpeg", ".png", ".webp")    # o resto (heic, gif, pdf...) vai como documento
ANEXOS_MAX = 10
ANEXO_MAX_BYTES = 50 * 1024 * 1024    # limite de upload da Bot API
_anexos_pendentes: dict[str, dict] = {}


ANEXO_TENTATIVAS = 3
ANEXO_BACKOFF = (2, 5)      # s entre tentativas
_TIMEOUTS = dict(connect_timeout=30, read_timeout=60, write_timeout=60)   # padrao (5s) estoura em foto


async def _baixar_anexo(midia, destino: Path) -> None:
    """get_file + download com timeout longo; repete so em TimedOut/NetworkError; BadRequest e subclasse de NetworkError mas nao e transitorio."""
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
    """Documento, foto ou video: baixa para disco e entrega o caminho ao Claude, com a legenda.
    Antes disto so havia handler de texto e todo anexo (legenda inclusive) era descartado."""
    if not authorized(update):
        return
    m = update.effective_message
    key, thread_id = topic_key(update)
    video = m.video or m.video_note
    midia = m.document or video or (m.photo[-1] if m.photo else None)    # foto: maior resolucao
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
    except Exception as e:                         # ex.: > 20 MB, limite da Bot API
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
    """O prompt de um envio com arquivos: o mesmo texto que o Wisp monta (WispCore MessageAttachments)."""
    return (f"[{_QUEM} enviou {len(itens)} arquivo(s) pelo {origem}, ja salvos nesta maquina:\n"
            + "\n".join(itens) + "]\n\n" + (texto or ANEXO_SEM_TEXTO))


def anexos_validos(brutos) -> list[tuple[Path, int]]:
    """Caminhos do `falar` com anexos: so arquivo regular dentro de ANEXOS_DIR, para a fila de controle
    nunca mandar ao Telegram um arquivo qualquer da maquina. Devolve (caminho REAL, bytes): quem posta abre
    o real, sem resolver de novo depois de um await. Tudo e checado antes de postar qualquer coisa."""
    if not brutos:
        return []
    if not isinstance(brutos, list) or len(brutos) > ANEXOS_MAX:
        raise ValueError(f"anexos precisa ser uma lista de ate {ANEXOS_MAX} caminhos")
    raiz = ANEXOS_DIR.resolve()
    out = []
    for bruto in brutos:
        p = Path(str(bruto))
        real = p.resolve() if p.is_absolute() else None
        if real is None or not real.is_relative_to(raiz) or not real.is_file():
            raise ValueError(f"anexo recusado: {p.name or bruto!r} nao e um arquivo da pasta de anexos do bot")
        tamanho = real.stat().st_size
        if tamanho > ANEXO_MAX_BYTES:
            raise ValueError(f"anexo recusado: {real.name} passa de {ANEXO_MAX_BYTES // (1024 * 1024)} MB")
        out.append((real, tamanho))
    return out


async def _postar_anexo(bot, chat_id: int, tid: int | None, p: Path) -> None:
    """Foto vai como foto; o resto, ou a foto que o Telegram recusa (dimensao, > 10 MB), como documento.
    `p` ja e o caminho real validado por anexos_validos."""
    with p.open("rb") as f:
        if p.suffix.lower() in ANEXO_FOTO:
            try:
                await bot.send_photo(chat_id, f, message_thread_id=tid, **_TIMEOUTS)
                return
            except BadRequest as e:
                log.warning("anexo %s recusado como foto (%s); indo como documento", p.name, e)
                f.seek(0)
        await bot.send_document(chat_id, f, filename=p.name, message_thread_id=tid, **_TIMEOUTS)


async def _recebido(m) -> None:
    """👀 na mensagem do usuario assim que ela chega, antes de fila ou turno."""
    try:
        await m.set_reaction("👀")
    except Exception as e:                        # cosmetico: nunca derruba o turno
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
    """Todo /comando que nao e do bot vai para o Claude, como no terminal.
    Medido 28/09: `claude -p "/eco-teste 42"` expande o comando com argumento."""
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
    store.reset(key)
    try:
        gravar_sessao(key)
        topicos.push_logo()
    except Exception as e:                         # a resposta ao /reset sai mesmo assim
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
    """Aceita atalho, caminho absoluto, ou nome de repo dentro de REPOS_ROOT."""
    if arg in ATALHOS:
        return os.path.expanduser(ATALHOS[arg])
    cand = os.path.expanduser(arg)
    if os.path.isdir(cand):
        return cand
    cand = os.path.join(REPOS_ROOT, arg)
    return cand if os.path.isdir(cand) else None


async def cmd_novo(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    """/novo <nome> [repo] — cria o topico da tarefa, com sessao e cwd proprios."""
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
    # o 2o argumento e repo se resolver para um diretorio; senao ja e instrucao
    if resto and (d := resolve_dir(resto[0])):
        cwd, resto = d, resto[1:]
    instrucao = " ".join(resto).strip()

    try:
        await abrir_topico(ctx.bot, chat.id, nome, cwd, instrucao, briefing=instrucao)
    except Exception as e:
        # quase sempre e falta da permissao "gerenciar topicos" no bot
        await reply(update, f"não consegui criar o tópico: <code>{html.escape(str(e))}</code>\n"
                            "confere se eu sou <b>admin</b> com permissão de gerenciar tópicos.", thread_id)
        return
    await reply(update, f"criado: <b>{html.escape(nome)}</b>"
                        + (" — já mandei a tarefa" if instrucao else ""), thread_id)


async def abrir_topico(bot, chat_id: int, nome: str, cwd: str, instrucao: str,
                       cabecalho: str = "", briefing: str = "") -> int:
    """Cria o topico, registra sessao + cwd e dispara o 1o turno solto.
    Usado pelo /novo e pela fila do Geral."""
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
        # solto de proposito: quem pediu responde na hora, o trabalho anda no topico
        _disparar(turno(bot, chat, tid, key, instrucao))
    return tid


async def abridor(app) -> None:
    """Consome a fila de topicos que o Geral pediu. Roda solto."""
    while True:
        await asyncio.sleep(2)
        for p in abrir_mod.pendentes():
            try:
                os.unlink(p["_file"])            # consome antes: pedido ruim nao repete em loop
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


async def _vigia_postar(app, rec: dict, texto: str) -> None:
    """Ativo: posta direto. Standby nao toca na API do Telegram: o pedido `postar` vai para a fila
    de quem le o Telegram (PC standby: fila local, o Mac drena; Mac standby: fila do PC, por ssh)."""
    h = app.bot_data.get("hosting")
    if h is None:
        raise RuntimeError("hosting ainda nao subiu")
    log.info("vigia %s: postando em %s (%s)", str(rec.get("session_id"))[:8], rec.get("thread"),
             texto.split("\n", 1)[0][:40])
    if h.ativo:
        await send(app.bot, SimpleNamespace(id=int(rec["chat"])), int(rec["thread"]), texto)
    elif hosting.MODO == "pair" and HOST == "mac":
        await asyncio.to_thread(ctl.pedir_pc, "postar", thread=rec["thread"], chat=rec["chat"], texto=texto)
    else:
        ctl.pedir("postar", thread=rec["thread"], chat=rec["chat"], texto=texto)


def _thread_morta(e: Exception) -> bool:
    m = str(e).lower()
    return "thread not found" in m or "topic_deleted" in m or "topic deleted" in m


async def _vigia_remover(sid: str) -> None:
    await asyncio.to_thread(vigia_mod.remover, sid)
    vigilia.soltar(f"vigia:{sid}")


async def _adotar_celular(app, sid: str, r: dict) -> None:
    """Modo celular: o turno do terminal acabou, o topico passa a ser dono da sessao (mesma conversa: --resume sid
    no cwd dela). O registro fica com modo="adotada" (so vigia se o terminal voltar a escrever); essa troca e o ultimo
    passo, entao qualquer falha antes dela faz o proximo tick tentar de novo."""
    key = f"{r['chat']}:{r['thread']}"
    cwd = os.path.expanduser(r.get("cwd") or DEFAULT_CWD)
    if not os.path.isdir(cwd):                     # --resume procura o jsonl pelo cwd: outro cwd nao acha a sessao
        log.warning("vigia %s: cwd %s nao existe aqui; nao adota", sid[:8], cwd)
        await asyncio.to_thread(vigia_mod.atualizar, sid, modo=None)    # volta a espelho comum
        await _vigia_postar(app, r, "não consigo continuar esta sessão daqui (cwd ausente neste host)")
        return
    principal = await asyncio.to_thread(vigia_mod._jsonl_principal, sid, cwd)
    try:
        base = principal.stat().st_mtime if principal else time.time()   # o que ja esta no jsonl nao e "terminal voltou"
    except OSError:
        base = time.time()
    store.adotar_sessao(key, sid)
    store.set_cwd(key, cwd)
    store.set_meta(key, espelho=None, celular=sid, escrita_bot=base)
    topicos.set_campos(key, onde="telegram")
    topicos.gravar_ponteiro(HOST, key, sid, True, time.time(), time.time(), sessao.tamanho_local(sid), cwd)
    vigilia.soltar(f"vigia:{sid}")
    topicos.push_logo()
    await _vigia_postar(app, r, "📱 a sessão agora é do Telegram: responda aqui, é a mesma conversa. "
                                "Voltou? Mande <code>terminal</code> aqui e a sessão volta para o terminal.")
    await asyncio.to_thread(vigia_mod.atualizar, sid, modo="adotada", avisado_volta=False)
    log.info("vigia %s: topico %s assumiu a sessao (modo celular)", sid[:8], key)


TERMINAL_VOLTOU = "o terminal voltou a rodar esta sessão; o que ele fizer aparece aqui quando terminar"


async def _vigia_adotada(app, sid: str, r: dict) -> None:
    """Sessao ja do topico: so interessa o terminal escrevendo por conta propria (tarefa em segundo plano que o
    reinvocou). Turno do bot em curso, ou jsonl que nao passou da ultima escrita do bot, nao e o terminal."""
    key = f"{r['chat']}:{r['thread']}"
    if lock_for(key).locked():
        return
    cwd = r.get("cwd", "")
    principal = await asyncio.to_thread(vigia_mod._jsonl_principal, sid, cwd)
    try:
        mtime = principal.stat().st_mtime if principal else 0.0
    except OSError:
        return
    escrita = _escrita_bot(key)
    if mtime <= escrita + 2:
        return
    av = await asyncio.to_thread(vigia_mod.avaliar, sid, cwd)
    if av.get("remover"):                          # /exit ou 12h parada: o registro sai calado, o topico segue dele
        await _vigia_remover(sid)
        return
    fim = av.get("fim") or ""
    if av["estado"] == "encerrada":
        if fim and fim != r.get("avisado_fim") and vigia_mod._ts(fim).timestamp() > escrita:
            texto = "✅ terminou"
            if av["ultimo_texto"]:
                texto += f"\n<pre>{html.escape(av['ultimo_texto'])}</pre>"
            await _vigia_postar(app, r, texto)
            await asyncio.to_thread(vigia_mod.atualizar, sid, avisado_fim=fim, avisado_volta=False)
    elif not r.get("avisado_volta"):
        await _vigia_postar(app, r, TERMINAL_VOLTOU)
        await asyncio.to_thread(vigia_mod.atualizar, sid, avisado_volta=True)


async def _vigia_um(app, sid: str, r: dict) -> None:
    """O espelho e persistente: "terminou" sai uma vez por turno acabado e o registro fica. Ele so sai por
    /exit, jsonl parado ha 12h (`remover` em avaliar), topico apagado/sumido ou desvincular."""
    todos = store.all()
    if not todos:                                  # store vazio = topics.json ilegivel, nao "topico sumido"
        return
    existe = any(t.key == f"{r.get('chat')}:{r.get('thread')}" for t in todos)
    if not existe:                                 # topico espelho sumiu do store: nada a vigiar
        await _vigia_remover(sid)
        return
    if r.get("modo") == "adotada":
        try:
            await _vigia_adotada(app, sid, r)
        except Exception as e:
            if _thread_morta(e):
                await _vigia_remover(sid)
                return
            raise
        return
    vigilia.segurar(f"vigia:{sid}")                # no-op fora do Mac; idempotente
    av = await asyncio.to_thread(vigia_mod.avaliar, sid, r.get("cwd", ""), None, r.get("desde"))
    novo = av["estado"]
    avisa_fim = novo == "encerrada" and vigia_mod.fim_a_avisar(av, r)
    adotar = r.get("modo") == "celular" and novo == "encerrada" and not av.get("remover")   # tambem re-tenta uma adocao que falhou
    if novo == r.get("avisado") and not avisa_fim and not av.get("remover") and not adotar:
        await asyncio.to_thread(vigia_mod.atualizar, sid, estado=novo, motivo=av["motivo"])
        return
    _pp = await asyncio.to_thread(vigia_mod._jsonl_principal, sid, r.get("cwd", ""))
    perg = await asyncio.to_thread(vigia_mod._pergunta_pendente, _pp) if _pp else None
    if perg and perg["id"] != r.get("avisado_pergunta"):
        try:
            await _vigia_postar(app, r, "❓ esperando você no terminal:\n" + html.escape(perg["texto"]))
            await asyncio.to_thread(vigia_mod.atualizar, sid, avisado_pergunta=perg["id"])
            r = {**r, "avisado_pergunta": perg["id"]}
        except Exception as e:
            if _thread_morta(e):
                await _vigia_remover(sid)
                return
            raise
    try:
        if novo == "travado":
            await _vigia_postar(app, r, f"⚠️ travou: {html.escape(av['motivo'])}")
        elif avisa_fim:
            texto = "✅ terminou"
            if av["ultimo_texto"]:
                texto += f"\n<pre>{html.escape(av['ultimo_texto'])}</pre>"
            await _vigia_postar(app, r, texto)
            r = {**r, "avisado_fim": av["fim"]}
            await asyncio.to_thread(vigia_mod.atualizar, sid, avisado_fim=av["fim"])   # antes de qualquer remocao
        if adotar:
            await _adotar_celular(app, sid, r)
            return
        if av.get("remover"):
            await _vigia_postar(app, r, f"👀 vigia encerrado: {html.escape(av['motivo'])}")
    except Exception as e:
        if _thread_morta(e):                       # topico apagado no Telegram: nao tenta para sempre
            log.warning("vigia %s: topico morto (%s); removendo", sid[:8], e)
            await _vigia_remover(sid)
            return
        raise
    if av.get("remover"):
        await _vigia_remover(sid)
        return
    # travado->rodando volta calado: so rearma o proximo aviso
    await asyncio.to_thread(vigia_mod.atualizar, sid, estado=novo, avisado=novo, motivo=av["motivo"])


async def _vigia_volta(app) -> None:
    todos = await asyncio.to_thread(vigia_mod.ler)
    for sid, r in todos.items():
        if r.get("host") != HOST:
            continue
        try:                                       # um registro ruim (thread morta, ssh caiu) nao para os outros
            await _vigia_um(app, sid, r)
        except Exception as e:
            log.warning("vigia %s falhou: %s", sid[:8], e)


async def vigia_loop(app) -> None:
    """A cada minuto avalia so as sessoes do terminal que o usuario pediu para vigiar (vigias.json), neste host."""
    while True:
        await asyncio.sleep(VIGIA_TICK_S)
        try:
            await _vigia_volta(app)
        except Exception as e:                     # um registro ruim nao pode matar a vigia
            log.warning("vigia falhou: %s", e)


def _chat_principal() -> int | None:
    return int(sorted(ALLOWED_CHAT_IDS)[0]) if ALLOWED_CHAT_IDS else None


async def _post_init(app) -> None:
    """O que roda nos dois hosts, ativo ou nao: abrir topicos
    pedidos AQUI (a fila e local de cada maquina)."""
    # asyncio.create_task e nao app.create_task: o PTB avisa quando se cria task
    # pelo Application antes dele estar "running". Mesmo defeito registrado como
    # pendencia na nota do bridge de maio; nao vale deixar voltar.
    for t in store.all():                           # topicos fixos (system_topics) nascem como "tópico N"
        nome = _CFG.system_topics.get(_thread_de(t.key))
        if nome and t.name != nome:
            store.renomear(t.key, nome)
    app.bot_data["abridor"] = asyncio.create_task(abridor(app))
    app.bot_data["controlador"] = asyncio.create_task(controlador(app))
    app.bot_data["vigia"] = asyncio.create_task(vigia_loop(app))   # tambem em standby: so registros locais


async def _ao_ativar(app, motivo: str) -> None:
    """So o host que le o Telegram publica o menu."""
    await topicos.pull()                          # topicos que o outro host gravou
    try:
        menu = menu_comandos()
        await app.bot.set_my_commands(menu)
        # escopo de grupo/privado vence o default no Telegram: um menu antigo nesses
        # escopos esconderia este. Publica o mesmo em todos.
        for escopo in (BotCommandScopeAllGroupChats(), BotCommandScopeAllPrivateChats()):
            await app.bot.set_my_commands(menu, scope=escopo)
        log.info("menu publicado: %d comandos", len(menu))
    except Exception as e:                        # menu e conveniencia: nunca derruba o bot
        log.warning("set_my_commands falhou: %s", e)


async def _ao_desativar(app, motivo: str) -> None:
    vigilia.soltar_todas()
    # sem aviso no chat (decisao de 30/09): a maquina que responde e invisivel
    # para o usuario. A troca fica so no log (wisp.hosting).





async def cmd_fim(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    """/fim — encerra o topico: solta a sessao, limpa runs pendentes e arquiva a thread."""
    if not authorized(update):
        return
    await encerrar(update, ctx)


async def encerrar(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    """Mesmo caminho para /fim e para a mensagem "encerrado"."""
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
    # solto: o resumo e um turno inteiro do Claude e o handler nao pode esperar
    _disparar(fechar(ctx.bot, chat_id, thread_id, key))


async def _apagar_topico(bot, chat_id: int, thread_id: int) -> str:
    """Apaga o topico do Telegram; sem permissao, arquiva; sem nenhuma, deixa. Devolve o que aconteceu."""
    try:
        await bot.delete_forum_topic(chat_id=chat_id, message_thread_id=thread_id)
        return "apagado"
    except Exception as e:
        # apagar exige o admin "apagar mensagens"; sem ele, ao menos arquiva
        log.warning("nao consegui apagar o topico %s: %s", thread_id, e)
        try:
            await bot.close_forum_topic(chat_id=chat_id, message_thread_id=thread_id)
            return "arquivado (sem permissão de apagar)"
        except Exception as e2:
            log.warning("nem arquivar o topico %s: %s", thread_id, e2)
            return "ficou aberto (sem permissão)"


async def fechar(bot, chat_id: int, thread_id: int, key: str) -> None:
    """Resumo no brain -> solta a sessao -> apaga o topico -> avisa no Geral.
    Se o resumo falhar, o topico NAO e apagado: apagar levaria a conversa junto."""
    chat = SimpleNamespace(id=chat_id)
    async with lock_for(key):
        t = topico_local(key)
        texto = ""
        if t.started and t.turns:
            res = await claude_run(RESUMO.format(brain=DEFAULT_CWD), session_id=t.session_id,
                                   cwd=t.cwd, started=True, model=MODELO,
                                   timeout=TOPICO_TIMEOUT,
                                   extra_prompt=regra_para(key, chat_id, thread_id))
            if not res.ok:
                await send(bot, chat, thread_id,
                           f"<b>não encerrei</b>: o resumo falhou, então o tópico fica.\n"
                           f"<pre>{html.escape(res.text[:1500])}</pre>\nManda <code>encerrado</code> de novo.")
                return
            store.bump(key, res.cost_usd)
            texto = res.text

        t = store.drop(key)
        if t is not None and t.meta.get("espelho"):    # espelho fechado: a vigia nao tem mais onde postar
            sid_esp = t.meta["espelho"]
            await asyncio.to_thread(vigia_mod.remover, sid_esp)
            vigilia.soltar(f"vigia:{sid_esp}")
        vigilia.soltar(key)                        # cobre /fim, "encerrado" e _ctl_encerrar
        topicos.set_status(key, "encerrado")
        topicos.push_logo()

    destino = await _apagar_topico(bot, chat_id, thread_id)

    nome = html.escape(t.name) if t else f"tópico {thread_id}"
    msg = f"✅ <b>{nome}</b> encerrado e {destino}" + (f" — {t.turns} turnos" if t else "")
    if texto:
        msg += f"\n\n{texto}"
    await send(bot, chat, None, msg)              # no Geral: o topico nao existe mais


# ---- topico entre Telegram e terminal (Mac/PC) — ver ctl.py e sessao.py ----

def _host_nome(h: str) -> str:
    return "Mac" if h.endswith("mac") else "PC"


def _thread_de(key: str) -> int:
    return int(key.rsplit(":", 1)[-1])


def _key_da_thread(thread) -> str | None:
    """Key do topico pelo numero do thread: primeiro no store, depois na nota do brain."""
    for t in store.all():
        if t.key.rsplit(":", 1)[-1] == str(thread):
            return t.key
    chat = _chat_principal()
    key = f"{chat}:{thread}" if chat else None
    return key if key and topicos.meta(key) else None


async def soltar_topico(bot, chat_id: int, thread_id: int, key: str, destino: str) -> dict:
    """Topico Telegram -> terminal. Sem resumo: a sessao continua em outro lugar, so
    o topico some. A nota passa a status terminal e diz onde o jsonl esta."""
    if destino not in ctl.destinos():
        raise ValueError(f"destino invalido: {destino}")
    if not thread_id:
        raise ValueError("o Geral nao vai para o terminal")
    chat = SimpleNamespace(id=chat_id)
    async with lock_for(key):
        t = store.get(key)
        if t is None:
            m = topicos.meta(key) or {}
            if m.get("status") == "terminal" and m.get("session_id"):     # idempotente
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
    """O comando que retoma a sessao no terminal. Em `pair` a CLI traz o jsonl da outra maquina antes de abrir."""
    if hosting.MODO == "pair":
        como = f"<code>wisp topic puxar {thread_id}</code>"
    else:
        como = (f"<code>claude --resume {t.session_id}</code> em "
                f"<code>{html.escape(topicos.portavel(t.cwd))}</code>")
    return f"↪ <b>{html.escape(t.name)}</b> saiu do Telegram ({onde_tg}). No terminal do {_host_nome(destino)}: {como}"


def _migrar_notas_orfas(sid: str, key_nova: str, tid: int) -> None:
    """A sessao ganhou topico novo: a nota terminal que ainda a apontava deixa de ser puxavel."""
    sessoes = topicos._ler_sessoes()
    for p in sorted(topicos.DIR.glob("topico-*.md")) if topicos.DIR.is_dir() else []:
        d = topicos._fm(topicos._ler(p))
        velha = d.get("topic_key", "")
        if velha:
            topicos._com_sessao(d, velha, sessoes)
        if velha and velha != key_nova and d.get("session_id") == sid and d.get("status") == "terminal":
            topicos.set_campos(velha, status="migrado", migrou_para=str(tid))


async def adotar_topico(bot, args: dict) -> dict:
    """Terminal -> topico Telegram novo, com a sessao inteira do terminal."""
    sid = args.get("session_id", "")
    if not sessao.valido(sid):
        raise ValueError(f"session_id invalido: {sid!r}")
    chat_id = _chat_principal()
    if not chat_id:
        raise ValueError("telegram.chat_id ausente: nao sei em que chat abrir o topico")
    for t in store.all():                          # idempotente
        if t.session_id == sid:
            return {"ok": True, "thread_id": _thread_de(t.key)}
    origem = args.get("origem_host") or HOST
    cwd = os.path.expanduser(args.get("cwd") or DEFAULT_CWD)
    if not os.path.isdir(cwd):
        log.warning("cwd %s nao existe aqui; adotando em %s", cwd, DEFAULT_CWD)
        cwd = DEFAULT_CWD
    if not await asyncio.to_thread(sessao.garantir_local, sid, cwd):
        if hosting.MODO == "pair" and HOST == "mac" and origem == "pc":
            await asyncio.to_thread(sessao.buscar_do_pc, sid, cwd)
        else:
            raise ValueError(f"o jsonl da sessao nao esta no {_host_nome(HOST)} (origem {origem})")
    nome = args.get("nome") or os.path.basename(cwd) or "terminal"
    tid = await abrir_topico(bot, chat_id, nome, cwd, "",
                             cabecalho=f"↩ continuando aqui o que estava no terminal do {_host_nome(origem)}",
                             briefing=f"Sessão adotada do terminal do {_host_nome(origem)}.")
    key = f"{chat_id}:{tid}"
    store.adotar_sessao(key, sid)
    topicos.set_campos(key, onde="telegram")
    topicos.gravar_ponteiro(HOST, key, sid, True, time.time(), time.time(),
                            sessao.tamanho_local(sid), cwd)
    _migrar_notas_orfas(sid, key, tid)
    topicos.push_logo()
    return {"ok": True, "thread_id": tid, "nome": nome}


async def _ctl_encerrar(bot, thread) -> dict:
    key = _key_da_thread(thread)
    if not key or not _thread_de(key):
        raise ValueError(f"topico {thread} desconhecido (ou e o Geral)")
    if store.get(key) is None:
        m = topicos.meta(key) or {}
        if m.get("status") in ("terminal", "encerrado"):          # ja saiu do Telegram: so fecha a nota
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
    """Topico NOVO que espelha uma sessao do terminal: nenhuma sessao do Claude, nenhum turno.
    Idempotente por session_id."""
    sid, nome = str(op.get("session_id") or ""), str(op.get("nome") or "").strip()
    if not sessao.valido(sid) or not nome:
        raise ValueError("vincular precisa de session_id valido e nome")
    async with _vincular_lock:                     # dois pedidos juntos nao criam dois topicos
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


async def _ctl_postar(bot, op: dict) -> dict:
    """So posta no topico; nunca roda turno (ao contrario do `falar`). `texto` e HTML como o `send` aceita."""
    texto = str(op.get("texto") or "").strip()
    if not texto:
        raise ValueError("texto vazio")
    if op.get("chat") not in (None, ""):
        chat_id, tid = int(op["chat"]), int(op.get("thread"))
    else:
        key = _key_da_thread(op.get("thread"))
        if not key:
            raise ValueError(f"topico {op.get('thread')} desconhecido")
        chat_id, tid = int(key.rsplit(":", 1)[0]), _thread_de(key)
    await send(bot, SimpleNamespace(id=chat_id), tid, texto)
    return {"ok": True, "thread_id": tid}


async def _ctl_desvincular(bot, op: dict) -> dict:
    sid = str(op.get("session_id") or "")
    key = _espelho_de(sid)
    if not key:
        raise ValueError(f"nenhum espelho para a sessao {sid[:8]}")
    await send(bot, SimpleNamespace(id=int(key.rsplit(":", 1)[0])), _thread_de(key), "vigia encerrado")
    _marcar_espelho(key, None)
    vigia_mod.remover(sid)                         # sem o registro a vigia nao volta a postar aqui
    vigilia.soltar(f"vigia:{sid}")
    return {"ok": True, "thread_id": _thread_de(key)}


async def _ctl_trazer(op: dict) -> dict:
    """Mac (o assumir do Wisp): traz o jsonl do topico do PC se la e maior, com o lock do topico seguro, para o
    pull nunca rodar junto com o alinhar_sessao de uma mensagem do celular. Lock ja tomado = um turno deste
    topico esta rodando e ja alinhou (ou alinha) a sessao: nao puxa de novo."""
    if HOST != "mac":
        raise ValueError("so o Mac traz a sessao do PC")
    sid = str(op.get("session_id") or "")
    if not sessao.valido(sid):
        raise ValueError(f"session_id invalido: {sid!r}")
    key = _key_da_thread(op.get("thread"))
    if not key:
        raise ValueError(f"topico {op.get('thread')} desconhecido")
    cwd = os.path.expanduser(str(op.get("cwd") or ""))
    if not os.path.isdir(cwd):
        cwd = DEFAULT_CWD
    try:
        prazo = min(max(float(op.get("prazo") or sessao.TRAZER_S), 5.0), 60.0)
    except (TypeError, ValueError):
        prazo = sessao.TRAZER_S
    lk = lock_for(key)
    if lk.locked():
        return {"ok": True, "session": "local"}
    async with lk:
        estado = await asyncio.to_thread(sessao.trazer_se_maior, sid, cwd, prazo)
    return {"ok": True, "session": estado}


async def ctl_executar(app, op: dict, origem: str) -> None:
    """Um pedido da fila de controle. Falha vira done ok=false; nunca derruba o loop."""
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
        elif nome == "adotar":
            res = await adotar_topico(app.bot, op)
        elif nome == "falar":
            key = _key_da_thread(op.get("thread"))
            if not key:
                raise ValueError(f"topico {op.get('thread')} desconhecido")
            texto = str(op.get("texto") or "").strip()
            anexos = anexos_validos(op.get("anexos"))
            if not texto and not anexos:
                raise ValueError("texto vazio")
            # Geral e thread 0 na chave, mas o Telegram o posta SEM message_thread_id (como o on_message: None)
            chat, tid = SimpleNamespace(id=int(key.rsplit(":", 1)[0])), _thread_de(key) or None
            origem_msg = html.escape(str(op.get("origem") or "terminal")[:80])
            await send(app.bot, chat, tid, f"<i>mensagem de outro tópico: {origem_msg}</i>"
                                           + (f"\n<pre>{html.escape(texto[:3000])}</pre>" if texto else ""))
            for p, _ in anexos:
                try:
                    await _postar_anexo(app.bot, chat.id, tid, p)
                except Exception as e:                 # o agente ainda le o arquivo do disco: o turno segue
                    log.warning("anexo %s nao foi ao topico: %s", p.name, e)
            if anexos:                                 # o mesmo bloco de uma foto do celular, vindo do Wisp
                texto = bloco_anexos("Wisp", [f"- {p} ({p.name}, {n} bytes)" for p, n in anexos], texto)
            # solto, como no abrir_topico: o turno() ja enfileira pelo lock do topico
            _disparar(turno(app.bot, chat, tid, key, texto))
            res = {"ok": True, "thread_id": tid or 0}
        elif nome == "vincular":
            res = await _ctl_vincular(app.bot, op)
        elif nome == "postar":
            res = await _ctl_postar(app.bot, op)
        elif nome == "desvincular":
            res = await _ctl_desvincular(app.bot, op)
        elif nome == "trazer":
            res = await _ctl_trazer(op)
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
    """Verbo de texto ("terminal", "puxa pro terminal [mac|pc]") dentro de um topico."""
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


PC_TICK_S = 30.0              # ocioso: o PC so e olhado a cada 30s
PC_RAPIDO_S = 5.0             # depois de achar op ou pedido de sessao
PC_RAPIDO_JANELA_S = 120.0    # por quanto tempo fica rapido
PC_FALHA_S = 20.0             # ssh falhou (PC fora): nao insiste a cada 5s
ESPELHO_S = 60.0              # PC lendo o Telegram: de minuto em minuto o Mac copia o que mudou


def _candidatas_pelas_notas() -> dict[str, str]:
    """Plano B: sid -> cwd local pelas notas (chegam do PC em ate 5 min via brain-sync)."""
    out = {}
    for m in topicos.abertos():
        sid = m.get("session_id", "")
        if m.get("session_host") == "pc" and m.get("session_started") == "true" and sessao.valido(sid):
            cwd = os.path.expanduser(m.get("cwd") or DEFAULT_CWD)
            out[sid] = cwd if os.path.isdir(cwd) else DEFAULT_CWD
    return out


def candidatas_espelho() -> dict[str, str]:
    """sid -> cwd local de todo topico iniciado no PC, lido do topics.json dele (ssh; chamar em
    thread). So se o ssh nao leu cai nas notas."""
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
    """O PC pediu a sessao: o Mac empurra o jsonl por ssh e so entao apaga o pedido."""
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
        if falhas[sid] >= 3:                       # pedido que nunca da certo nao repete para sempre
            falhas.pop(sid, None)
            await asyncio.to_thread(ctl.apagar_pedido_pc, sid)
    finally:
        em_voo.discard(sid)


async def _drenar_pc(app, ativo: bool, em_voo: set, falhas: dict) -> tuple[bool, bool]:
    """Uma volta no PC: (achou op ou pedido, ssh_ok). Roda como task propria: um ssh lento
    nunca atrasa a fila local."""
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
    """Consome a fila de controle (ctl.py). So age enquanto este host le o Telegram.
    No Mac, tambem drena a fila do PC por ssh (o PC nao alcanca o Mac) e empurra as
    sessoes que o PC pediu — estas ativo ou nao, pois o Mac sempre olha o PC.
    A fila local vem primeiro a cada ciclo; o PC so e olhado se o hosting o viu de pe."""
    proximo_pc, rapido_ate, ciclos = 0.0, 0.0, 0
    drenando: asyncio.Task | None = None
    espelhando: asyncio.Task | None = None
    proximo_espelho = 0.0
    em_voo: set[str] = set()
    falhas: dict[str, int] = {}
    resolvendo: asyncio.Task | None = None
    while True:
        await asyncio.sleep(2)
        try:
            h = app.bot_data.get("hosting")
            ativo = bool(h and h.ativo)
            if ativo:
                for p in ctl.pendentes():
                    ctl.consumir(p)                # consome antes: pedido ruim nao repete em loop
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
                # None = PC alcancavel mas sem bot (ou ssh falhou): e justo quando o Mac
                # le o Telegram e o terminal do PC precisa ser drenado; so o offline pula
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
                espelhando = asyncio.create_task(_espelhar())   # task propria: ssh lento nao atrasa a fila local
            if resolvendo is not None and resolvendo.done():
                if not resolvendo.cancelled() and resolvendo.exception():
                    log.warning("em-voo falhou: %s", resolvendo.exception())
                resolvendo = None
            if resolvendo is None and any(e["fim"] for e in _em_voo_mac.values()):
                resolvendo = asyncio.create_task(_resolver_em_voo())
            ciclos += 1
            if ciclos % 1800 == 0:
                ctl.limpar()
        except Exception as e:                     # um ciclo ruim nao pode matar o loop
            log.warning("controlador falhou: %s", e)


def main() -> int:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    # 🔴 httpx loga a URL inteira de cada request, e a URL da API do Telegram
    # CARREGA O TOKEN. Em INFO isso despeja a credencial no arquivo de log a cada
    # chamada. Medido em 28/09, com vazamento real. WARNING mata isso.
    for noisy in ("httpx", "httpcore", "telegram.ext.Updater"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
    try:
        cfg = load_bot_config()
    except ConfigError as e:                      # uma frase, sem subir nada: o launchd mostra no log
        print(e, file=sys.stderr)
        return 2
    token = cfg.token

    # 🔑 Sem concurrent_updates o PTB processa UM update por vez, e a arquitetura
    # inteira cai: o Geral fica esperando o topico terminar. As travas por topico
    # abaixo so tem efeito com isto ligado. Medido em 28/09: respostas saiam em fila.
    app = (Application.builder()
           .bot(polling.criar_bot(token))
           .concurrent_updates(True)
           .build())
    app.add_handler(CommandHandler("novo", _contado(cmd_novo)))
    app.add_handler(CommandHandler("fim", _contado(cmd_fim)))
    app.add_handler(CommandHandler("chatid", _contado(cmd_chatid)))
    app.add_handler(CommandHandler("status", _contado(cmd_status)))
    app.add_handler(CommandHandler("reset", _contado(cmd_reset)))
    app.add_handler(CommandHandler("clear", _contado(cmd_reset)))          # o reflexo do terminal
    app.add_handler(CommandHandler("cwd", _contado(cmd_cwd)))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, _contado(on_message)))
    app.add_handler(MessageHandler(filters.Document.ALL | filters.PHOTO | filters.VIDEO | filters.VIDEO_NOTE, _contado(on_attachment)))
    # depois dos CommandHandler: so recebe o /comando que nao e do bot
    app.add_handler(MessageHandler(filters.COMMAND, _contado(on_passthrough)))
    log.info("wisp-bot no ar · host=%s · hosting=%s · modelo=%s · cwd=%s", HOST, hosting.MODO, MODELO, DEFAULT_CWD)
    asyncio.run(_viver(app))
    return 0


def _turno_rodando() -> bool:
    """Algum turno deste host rodando ou na fila (inclui o resumo do /fim, que so segura o lock), um anexo na janela
    de juntar, um handler do Telegram no meio ou um pedido da fila disparado: o PC so solta a leitura para o claim do
    Mac quando isto e False. A espera do terminal no modo celular segura o lock e conta: a mensagem roda aqui depois
    (soltar antes faria o Mac puxar o jsonl que o terminal daqui ainda grava)."""
    return (_em_curso > 0 or bool(_anexos_pendentes) or any(n > 0 for n in _turnos_mac.values())
            or any(lk.locked() for lk in _locks.values()))


async def _viver(app) -> None:
    """Ciclo manual do PTB em vez de run_polling: a leitura do Telegram liga e
    desliga conforme o outro host (hosting.py), com o bot inteiro de pe."""
    parar = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, parar.set)
    async with app:                               # initialize + shutdown
        await app.start()
        await _post_init(app)
        h = hosting.Hosting(app, lambda m: _ao_ativar(app, m), lambda m: _ao_desativar(app, m),
                            passar_sessoes, ocupado=_turno_rodando,
                            antes_de_soltar=lambda: topicos.push_agora(hosting.HANDOVER_PC_S))
        app.bot_data["hosting"] = h
        polling.vigiar(lambda: h.ativo)
        vida = asyncio.create_task(h.rodar())

        async def _avisar_geral(texto: str) -> None:
            await app.bot.send_message(_chat_principal(), texto)   # sem thread = Geral
        canario = asyncio.create_task(saude.vigiar(_avisar_geral, parar))
        await asyncio.wait([vida, asyncio.create_task(parar.wait())],
                           return_when=asyncio.FIRST_COMPLETED)
        canario.cancel()
        if vida.done() and vida.exception():
            log.error("hosting morreu: %r", vida.exception())
        vida.cancel()
        if app.updater.running:
            await app.updater.stop()
        # a nota do ultimo turno (session_*) tem que chegar ao git antes de morrer: em 21/10 o
        # stop caiu na espera do push_logo e o outro host nao achou a sessao para adotar
        try:
            await asyncio.wait_for(topicos.push_agora(), timeout=15)
        except asyncio.TimeoutError:
            log.warning("push da saida nao terminou em 15s")
        hosting.gravar_estado("off")
        await app.stop()


if __name__ == "__main__":
    raise SystemExit(main())
