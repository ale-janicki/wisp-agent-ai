"""Aprovacoes no Telegram: quando o claude de um turno pede permissao (um `can_use_tool` do canal de permissao do
proprio Claude Code), o bot posta um cartao com Permitir / Negar e devolve a resposta do dono. O modelo nao
consegue responder esse canal: so quem escreve no stdin do processo, que e o bot."""
from __future__ import annotations
import asyncio, html, json, logging, unicodedata, uuid

log = logging.getLogger("wisp-bot.aprovacoes")

LIMITE_MENSAGEM = 4000  # o Telegram recusa mais de 4096 caracteres; o HTML escapado conta
LIMITE_RESUMO = 300
VALIDADE_S = 600        # sem resposta em 600 s, nega
PREFIXO = "aprov"
EMAIL = "mcp__wisp-email__email_send"
MAC_SEND = "mcp__wisp-mac__mac_send"

NEGADO_NO_TELEGRAM = ("O usuário negou esta ação no Telegram. Não tente de novo do mesmo jeito; "
                      "siga sem ela ou pergunte o que fazer.")
EXPIROU = ("Ninguém respondeu ao pedido de permissão no Telegram a tempo, então a ação foi negada. "
           "Siga sem ela ou pergunte o que fazer.")
LONGO_DEMAIS = ("O pedido é grande demais para o Telegram mostrar inteiro, então não foi aprovado. "
                "Peça ao usuário para fazer isso pelo app.")


def _resumo(pedido: dict) -> str:
    resumo = str(pedido["summary"])
    return resumo[:LIMITE_RESUMO] + "…" if len(resumo) > LIMITE_RESUMO else resumo


def _completo(pedido: dict) -> str:
    return f"<b>{html.escape(_resumo(pedido))}</b>\n\n{html.escape(str(pedido['detail']))}"


def cabe(pedido: dict) -> bool:
    """O texto inteiro, ja escapado, cabe numa mensagem do Telegram. O dono nunca aprova aqui o que nao viu inteiro."""
    return len(_completo(pedido)) <= LIMITE_MENSAGEM


def texto(pedido: dict) -> str:
    if cabe(pedido):
        return _completo(pedido)
    return (f"<b>{html.escape(_resumo(pedido))}</b>\n\ntexto longo ({len(str(pedido['detail']))} caracteres), "
            "aprove pelo app")


def motor_de(req: dict) -> str:
    return "Codex" if req.get("engine") == "codex" else "Claude"


def escapar(texto: str) -> str:
    saida = []
    for ch in texto:
        if ch in "\n\t" or not unicodedata.category(ch).startswith("C"):
            saida.append(ch)
        else:
            saida.append(f"\\u{{{ord(ch):04x}}}")
    return "".join(saida)


def descrever(req: dict) -> dict:
    pedido = _descrever(req)
    return {**pedido, "summary": escapar(str(pedido["summary"])), "detail": escapar(str(pedido["detail"]))}


def _descrever(req: dict) -> dict:
    """O `request` de um can_use_tool vira {summary, detail}: o que o dono le antes de permitir."""
    ferramenta = str(req.get("tool_name") or "uma ferramenta")
    motor = motor_de(req)
    entrada = req.get("input") if isinstance(req.get("input"), dict) else {}
    if ferramenta == "Bash" and isinstance(entrada.get("command"), str):
        return {"summary": f"O {motor} quer rodar um comando", "detail": entrada["command"]}
    corpo = json.dumps(entrada, ensure_ascii=False, indent=2, sort_keys=True)
    if motor == "Codex" and ferramenta == EMAIL:
        return {"summary": "O Codex quer enviar um e-mail", "detail": corpo}
    if motor == "Codex" and ferramenta == MAC_SEND:
        return {"summary": "O Codex quer enviar uma mensagem pelo app", "detail": corpo}
    return {"summary": f"O {motor} quer usar {ferramenta}", "detail": corpo}


def _teclado(token: str):
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup
    return InlineKeyboardMarkup([[InlineKeyboardButton("Permitir", callback_data=f"{PREFIXO}:{token}:allow"),
                                  InlineKeyboardButton("Negar", callback_data=f"{PREFIXO}:{token}:deny")]])


class Aprovacoes:
    def __init__(self, bot, owner_id: int, validade: float = VALIDADE_S):
        self.bot, self.owner_id, self.validade = bot, owner_id, validade
        self._abertos: dict[str, asyncio.Future] = {}   # token do cartao -> future(bool)

    async def _fechar(self, chat_id: int, message_id: int, corpo: str, rotulo: str) -> None:
        try:
            await self.bot.edit_message_text(f"{corpo}\n\n<i>{rotulo}</i>", chat_id=chat_id, message_id=message_id,
                                             parse_mode="HTML", reply_markup=None)
        except Exception as e:
            log.warning("nao consegui editar a mensagem %s: %s", message_id, e)

    async def pedir(self, chat_id: int, thread_id: int | None, req: dict) -> str | None:
        """Posta o cartao e espera o dono. None permite; um texto nega e e o que o modelo le."""
        pedido = descrever(req)
        corpo = texto(pedido)
        kw: dict = {"parse_mode": "HTML", "message_thread_id": thread_id}
        token = uuid.uuid4().hex
        if cabe(pedido):
            kw["reply_markup"] = _teclado(token)
        msg = await self.bot.send_message(chat_id, corpo, **kw)
        if "reply_markup" not in kw:
            await self._fechar(chat_id, msg.message_id, corpo, "negado: não cabe no Telegram")
            return LONGO_DEMAIS
        futuro = asyncio.get_running_loop().create_future()
        self._abertos[token] = futuro
        try:
            permitir = await asyncio.wait_for(futuro, self.validade)
        except asyncio.TimeoutError:
            await self._fechar(chat_id, msg.message_id, corpo, "expirou")
            return EXPIROU
        except asyncio.CancelledError:
            await self._fechar(chat_id, msg.message_id, corpo, f"cancelado (o {motor_de(req)} desistiu)")
            raise
        finally:
            self._abertos.pop(token, None)
        await self._fechar(chat_id, msg.message_id, corpo, "permitido" if permitir else "negado")
        return None if permitir else NEGADO_NO_TELEGRAM

    async def pressionou(self, update, context=None) -> None:
        q = update.callback_query
        partes = (q.data or "").split(":")
        if len(partes) != 3 or partes[0] != PREFIXO or partes[2] not in ("allow", "deny"):
            await q.answer()
            return
        if q.from_user.id != self.owner_id:
            await q.answer("só o dono do Wisp pode responder", show_alert=True)
            return
        futuro = self._abertos.get(partes[1])
        if futuro is None or futuro.done():
            await q.answer("expirou ou já respondido")
            return
        futuro.set_result(partes[2] == "allow")
        await q.answer("permitido" if partes[2] == "allow" else "negado")
