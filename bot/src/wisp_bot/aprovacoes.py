"""Aprovacoes no Telegram: le os pedidos de ferramentas irreversiveis (arquivos em
$XDG_STATE_HOME/wisp/approvals, mesmo contrato de cli/src/wisp/approvals.py) e deixa o dono
responder com Permitir / Negar. O wisp_bot nao depende do pacote wisp: leitor e decisor sao reimplementados aqui."""
from __future__ import annotations
from collections.abc import Callable
import asyncio, html, json, logging, os, re, time
from pathlib import Path

log = logging.getLogger("wisp-bot.aprovacoes")

_ID = re.compile(r"[0-9a-f]{32}")
_CAMPOS = ("id", "tool", "summary", "detail", "created", "thread")
LIMITE_DETALHE = 3500
LIMITE_RESUMO = 300
CORTE = "… (veja inteiro no app)"
INTERVALO_S = 2.0
VALIDADE_S = 600        # a ferramenta desiste em 600 s; pedido mais velho e orfao e nao aparece


def diretorio() -> Path | None:
    """None se nao existe ou e symlink: o bot nunca cria o diretorio (sem diretorio, sem pedidos)."""
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local/state")
    d = Path(base) / "wisp" / "approvals"
    if d.is_symlink() or not d.is_dir():
        return None
    return d


_ROTULOS = {"deny": "negado", "cancelled": "cancelado (a conversa parou)", "expired": "expirou",
            "failed": "permitido, mas o envio falhou"}


def _limpar_tumulos(d: Path, agora: float) -> None:
    """`<id>.done` mais velho que VALIDADE_S nao interessa a ninguem: apaga."""
    for f in d.glob("*.done"):
        try:
            if agora - f.lstat().st_mtime > VALIDADE_S:
                f.unlink(missing_ok=True)
        except OSError:
            continue


def _ler_tumulo(d: Path | None, id: str) -> str | None:
    """O desfecho que a ferramenta deixou em `<id>.done` (e apaga o arquivo); None se nao ha ou nao vale."""
    if d is None:
        return None
    f = d / f"{id}.done"
    try:
        dados = json.loads(f.read_text())
    except (OSError, ValueError):
        return None
    finally:
        f.unlink(missing_ok=True)
    if not isinstance(dados, dict) or dados.get("id") != id:
        return None
    desfecho = dados.get("outcome")
    return desfecho if desfecho in ("allow", "deny", "cancelled", "expired", "failed") else None


def _numero(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def pendentes(d: Path | None = None, agora: Callable[[], float] = time.time) -> list[dict]:
    d = d or diretorio()
    if d is None:
        return []
    achados = []
    for f in d.glob("*.json"):
        if not _ID.fullmatch(f.stem) or (d / f"{f.stem}.decision").exists():
            continue
        try:
            req = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(req, dict) or any(k not in req for k in _CAMPOS) or req["id"] != f.stem:
            continue
        if not _numero(req["created"]) or agora() - req["created"] > VALIDADE_S:
            continue
        achados.append(req)
    return sorted(achados, key=lambda r: r["created"])


def _ainda_aberto(d: Path, id: str) -> bool:
    """Falso quando a ferramenta ja desistiu (o tumulo diz expired ou cancelled) ou sumiu com o pedido sem deixar
    tumulo: uma resposta gravada agora apareceria como "permitido" para algo que nao aconteceu."""
    try:
        dados = json.loads((d / f"{id}.done").read_text())
    except (OSError, ValueError):
        return (d / f"{id}.json").exists()
    return not (isinstance(dados, dict) and dados.get("outcome") in ("expired", "cancelled"))


def decidir(id: str, permitir: bool, d: Path | None = None) -> bool:
    if not _ID.fullmatch(id):
        return False
    d = d or diretorio()
    if d is None or not (d / f"{id}.json").exists():
        return False
    alvo = d / f"{id}.decision"
    try:
        fd = os.open(alvo, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except OSError:
        return False
    try:
        with os.fdopen(fd, "w") as f:
            f.write("allow" if permitir else "deny")
    except OSError:
        alvo.unlink(missing_ok=True)
        return False
    if not _ainda_aberto(d, id):
        alvo.unlink(missing_ok=True)
        return False
    return True


def texto(req: dict) -> str:
    detalhe = str(req["detail"])
    if len(detalhe) > LIMITE_DETALHE:
        detalhe = detalhe[:LIMITE_DETALHE] + CORTE
    resumo = str(req["summary"])
    if len(resumo) > LIMITE_RESUMO:
        resumo = resumo[:LIMITE_RESUMO] + "…"
    return f"<b>{html.escape(resumo)}</b>\n\n{html.escape(detalhe)}"


def _teclado(id: str):
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup
    return InlineKeyboardMarkup([[InlineKeyboardButton("Permitir", callback_data=f"aprov:{id}:allow"),
                                  InlineKeyboardButton("Negar", callback_data=f"aprov:{id}:deny")]])


class Aprovacoes:
    def __init__(self, bot, chat_id: int, owner_id: int, d: Path | None = None,
                 estado: Path | None = None, ativo: Callable[[], bool] = lambda: True,
                 agora: Callable[[], float] = time.time):
        self.bot, self.chat_id, self.owner_id, self._d = bot, chat_id, owner_id, d
        self._estado, self._ativo, self._agora = estado, ativo, agora
        # id -> (chat, thread, message_id, texto, created)
        self.postados: dict[str, tuple[int, int | None, int, str, float]] = self._carregar()

    def _dir(self) -> Path | None:
        return self._d or diretorio()

    def _carregar(self) -> dict:
        if self._estado is None:
            return {}
        try:
            cru = json.loads(self._estado.read_text())
            # estado antigo sem created (4 campos) vira 0: o rotulo cai em "expirou"
            return {i: (int(v[0]), v[1], int(v[2]), str(v[3]), float(v[4]) if len(v) > 4 else 0.0)
                    for i, v in cru.items() if _ID.fullmatch(i)}
        except (OSError, ValueError, TypeError, IndexError, AttributeError):
            return {}

    def _gravar(self) -> None:
        if self._estado is None:
            return
        try:
            self._estado.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._estado.with_suffix(".tmp")
            tmp.write_text(json.dumps({i: list(v) for i, v in self.postados.items()}), "utf-8")
            tmp.replace(self._estado)          # troca atomica: nunca deixa json pela metade
        except OSError as e:
            log.warning("nao gravei o estado das aprovacoes: %s", e)

    async def _postar(self, id: str, req: dict) -> None:
        thread = req["thread"] if isinstance(req["thread"], int) else None
        corpo = texto(req)
        kw = dict(parse_mode="HTML", reply_markup=_teclado(id))
        try:
            msg = await self.bot.send_message(self.chat_id, corpo, message_thread_id=thread, **kw)
        except Exception as e:
            if thread is None or "thread" not in str(e).lower():
                raise
            log.warning("topico %s nao existe; aprovacao %s vai para o Geral", thread, id[:8])
            thread = None
            msg = await self.bot.send_message(self.chat_id, corpo, **kw)
        self.postados[id] = (self.chat_id, thread, msg.message_id, corpo, float(req["created"]))
        self._gravar()

    async def varrer(self) -> None:
        if not self._ativo():
            return
        d = self._dir()
        abertos = {r["id"]: r for r in pendentes(d, self._agora)}
        for id, req in abertos.items():
            if id in self.postados:
                continue
            try:
                await self._postar(id, req)
            except Exception as e:                  # um pedido ruim nao impede o proximo
                log.warning("nao consegui postar a aprovacao %s: %s", id[:8], e)
        if d is not None:
            _limpar_tumulos(d, self._agora())
        gone = [i for i in self.postados if i not in abertos and not self._em_curso(d, i)]
        for id in gone:
            chat, _, mid, corpo, criado = self.postados.pop(id)
            # A ferramenta deixa `<id>.done` com o desfecho antes de apagar pedido e .decision. Se o
            # bot ainda tinha o pedido em `postados`, nao foi ele quem decidiu: foi o app.
            desfecho = _ler_tumulo(d, id)
            if desfecho == "allow":
                rotulo = "permitido no app"
            elif desfecho is not None:
                rotulo = _ROTULOS[desfecho]
            else:       # sem tumulo: so a idade: antes dos 600 s alguem respondeu no app; depois, expirou
                rotulo = "respondido no app" if self._agora() - criado < VALIDADE_S else "expirou"
            await self._fechar(chat, mid, corpo, rotulo)
        if gone:
            self._gravar()

    def _em_curso(self, d: Path | None, id: str) -> bool:
        """Decidido mas a ferramenta ainda nao retirou o pedido (ela escreve `<id>.done` antes de apagar o .json):
        segue postado, sem rotulo, ate a proxima varredura. Pedido orfao (mais velho que VALIDADE_S) nao espera."""
        if d is None or not (d / f"{id}.json").exists():
            return False
        return self._agora() - self.postados[id][4] <= VALIDADE_S

    async def _fechar(self, chat: int, mid: int, corpo: str, rotulo: str) -> None:
        try:
            await self.bot.edit_message_text(f"{corpo}\n\n<i>{rotulo}</i>", chat_id=chat, message_id=mid,
                                             parse_mode="HTML", reply_markup=None)
        except Exception as e:
            log.warning("nao consegui editar a mensagem %s: %s", mid, e)

    async def pressionou(self, update, context=None) -> None:
        q = update.callback_query
        partes = (q.data or "").split(":")
        if len(partes) != 3 or partes[0] != "aprov" or partes[2] not in ("allow", "deny"):
            await q.answer()
            return
        if q.from_user.id != self.owner_id:
            await q.answer("só o dono do Wisp pode responder", show_alert=True)
            return
        _, id, acao = partes
        d = self._dir()
        existia = d is not None and (d / f"{id}.json").exists()
        ok = decidir(id, acao == "allow", d)
        info = self.postados.pop(id, None)          # antes de qualquer await: varrer nao sobrescreve o rotulo
        self._gravar()
        if ok:
            rotulo = "permitido" if acao == "allow" else "negado"
        else:
            rotulo = "já respondido" if existia else "expirou ou já respondido"
        await q.answer(rotulo)
        corpo = info[3] if info else texto_da_mensagem(q)
        try:
            await q.edit_message_text(f"{corpo}\n\n<i>{rotulo}</i>", parse_mode="HTML", reply_markup=None)
        except Exception as e:
            log.warning("nao consegui editar a mensagem de %s: %s", id, e)

    async def loop(self) -> None:
        while True:
            try:
                await self.varrer()
            except Exception as e:                  # um pedido ruim nao pode matar a varredura
                log.warning("varredura de aprovacoes falhou: %s", e)
            await asyncio.sleep(INTERVALO_S)


def texto_da_mensagem(q) -> str:
    m = getattr(q, "message", None)
    return html.escape(getattr(m, "text", None) or "")
