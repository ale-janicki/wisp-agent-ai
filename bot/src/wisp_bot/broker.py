"""Canal de aprovacao do e-mail sob o Codex, que nao tem um prompt de permissao proprio. O bot abre um socket Unix numa
pasta 0700 e o servidor de e-mail do Wisp (`WISP_SEND_GATE=broker`) pede por ele antes de enviar. O socket so tem um verbo
do cliente, `request`: quem responde e o cartao Permitir/Negar do dono, nunca o processo que pediu."""
from __future__ import annotations
import asyncio, json, logging, os, shutil, tempfile
from typing import Awaitable, Callable

log = logging.getLogger("wisp-bot.broker")

SOCKET_ENV = "WISP_APPROVAL_SOCKET"
OP_REQUEST = "request"
TOOLS = {"email_send": "mcp__wisp-email__email_send"}
LINHA_MAX = 1 << 20
LEITURA_S = 10
VALIDADE_S = 610   # um pouco acima dos 600 s do cartao, para a recusa do cartao chegar antes

PedirPermissao = Callable[[dict], Awaitable[str | None]]

MALFORMADO = "O pedido de aprovação não foi entendido, então nada foi enviado."
FALHOU = "Não consegui pedir a aprovação, então nada foi enviado."
EXPIROU = "Ninguém respondeu ao pedido de aprovação a tempo, então nada foi enviado."


def _vivo(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def varrer_mortos(pasta: str | None = None) -> None:
    base = pasta or tempfile.gettempdir()
    try:
        nomes = os.listdir(base)
    except OSError:
        return
    for nome in nomes:
        partes = nome.split("-")
        if len(partes) != 3 or partes[0] != "wisp" or not partes[1].isdigit() or len(partes[2]) != 8:
            continue
        pid = int(partes[1])
        caminho = os.path.join(base, nome)
        if pid == os.getpid() or _vivo(pid) or not os.path.isdir(caminho) or os.path.islink(caminho):
            continue
        try:
            if set(os.listdir(caminho)) <= {"b"}:
                shutil.rmtree(caminho, ignore_errors=True)
        except OSError:
            continue


def _pedido(linha: bytes) -> dict | None:
    try:
        msg = json.loads(linha)
    except ValueError:
        return None
    if not isinstance(msg, dict) or msg.get("op") != OP_REQUEST or msg.get("tool") not in TOOLS:
        return None
    entrada = msg.get("input")
    if not isinstance(entrada, dict):
        return None
    return {"tool_name": TOOLS[msg["tool"]], "input": entrada, "engine": "codex"}


class Broker:
    def __init__(self, decidir: PedirPermissao, validade: float = VALIDADE_S):
        self.decidir, self.validade = decidir, validade
        self.path = ""
        self._pasta = ""
        self._server: asyncio.AbstractServer | None = None
        self._ativos: set[asyncio.Task] = set()

    async def start(self) -> "Broker":
        varrer_mortos()
        self._pasta = tempfile.mkdtemp(prefix=f"wisp-{os.getpid()}-")
        self.path = os.path.join(self._pasta, "b")
        try:
            self._server = await asyncio.start_unix_server(self._atender, path=self.path, limit=LINHA_MAX)
            os.chmod(self.path, 0o600)
        except OSError:
            shutil.rmtree(self._pasta, ignore_errors=True)
            raise
        return self

    async def close(self) -> None:
        if self._server:
            self._server.close()
        for tarefa in list(self._ativos):
            tarefa.cancel()
        if self._ativos:
            await asyncio.gather(*self._ativos, return_exceptions=True)
        if self._server:
            await self._server.wait_closed()
        shutil.rmtree(self._pasta, ignore_errors=True)

    async def _responder(self, writer, corpo: dict) -> None:
        try:
            writer.write(json.dumps(corpo, ensure_ascii=False).encode() + b"\n")
            await writer.drain()
        except (ConnectionError, OSError):
            pass

    async def _atender(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        tarefa = asyncio.current_task()
        self._ativos.add(tarefa)
        try:
            await self._servir(reader, writer)
        except asyncio.CancelledError:
            pass
        except Exception as e:
            log.warning("pedido de aprovacao falhou: %s", e)
        finally:
            self._ativos.discard(tarefa)
            writer.close()

    async def _servir(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            linha = await asyncio.wait_for(reader.readline(), LEITURA_S)
        except (asyncio.TimeoutError, ValueError, asyncio.LimitOverrunError):
            await self._responder(writer, {"decision": "deny", "message": MALFORMADO})
            return
        pedido = _pedido(linha)
        if pedido is None:
            await self._responder(writer, {"decision": "deny", "message": MALFORMADO})
            return
        decisao = asyncio.ensure_future(self.decidir(pedido))
        sumiu = asyncio.ensure_future(reader.read(1))
        try:
            feitos, _ = await asyncio.wait({decisao, sumiu}, timeout=self.validade, return_when=asyncio.FIRST_COMPLETED)
        except asyncio.CancelledError:
            decisao.cancel(); sumiu.cancel()
            await asyncio.gather(decisao, sumiu, return_exceptions=True)
            raise
        if decisao in feitos:
            sumiu.cancel()
            try:
                negativa = decisao.result()
            except Exception as e:
                log.warning("o cartao de aprovacao falhou: %s", e)
                await self._responder(writer, {"decision": "deny", "message": FALHOU})
                return
            if negativa is None:
                await self._responder(writer, {"decision": "allow"})
            else:
                await self._responder(writer, {"decision": "deny", "message": str(negativa)})
            return
        decisao.cancel(); sumiu.cancel()
        await asyncio.gather(decisao, sumiu, return_exceptions=True)
        if sumiu not in feitos:
            await self._responder(writer, {"decision": "deny", "message": EXPIROU})
