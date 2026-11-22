"""Canal de aprovacao do e-mail, para qualquer motor. O bot abre um socket Unix numa pasta 0700 e o servidor de e-mail do
Wisp pede por ele antes de enviar; nao existe chave que desligue isso. O socket so tem um verbo do cliente, `request`, e
quem responde nunca e o processo que pediu: sob o Codex e o cartao Permitir/Negar do dono (`vivo`); sob o Claude e um
bilhete de uso unico que o proprio bot cunha, na memoria, quando o dono permite o `can_use_tool` do `email_send`, preso ao
hash do conteudo exato do e-mail (para, cc, assunto, corpo) e valido por `BILHETE_S`. Sem bilhete que combine, nada sai.
So um cliente com o mesmo uid do bot e atendido, e so um cartao fica aberto por vez."""
from __future__ import annotations
import asyncio, hashlib, json, logging, os, shutil, socket, struct, sys, tempfile, time
from typing import Awaitable, Callable

log = logging.getLogger("wisp-bot.broker")

SOCKET_ENV = "WISP_APPROVAL_SOCKET"
OP_REQUEST = "request"
TOOLS = {"email_send": "mcp__wisp-email__email_send", "mac_send": "mcp__wisp-mac__mac_send"}
LINHA_MAX = 1 << 20
LEITURA_S = 10
VALIDADE_S = 610   # um pouco acima dos 600 s do cartao, para a recusa do cartao chegar antes
BILHETE_S = 120

PedirPermissao = Callable[[dict], Awaitable[str | None]]

MALFORMADO = "O pedido de aprovação não foi entendido, então nada foi enviado."
FALHOU = "Não consegui pedir a aprovação, então nada foi enviado."
EXPIROU = "Ninguém respondeu ao pedido de aprovação a tempo, então nada foi enviado."
SEM_BILHETE = ("Não há aprovação do usuário para este e-mail exato (ou ela já foi usada ou expirou), então nada foi enviado. "
               "Peça o envio de novo e espere a aprovação.")
OCUPADO = "Já existe um pedido de aprovação aguardando o usuário nesta conversa, então nada foi enviado."


def huella(ferramenta: str, entrada: dict) -> str | None:
    def texto(valor) -> bytes | None:
        if not isinstance(valor, str):
            return None
        dados = valor.encode("utf-8", "surrogatepass")
        return str(len(dados)).encode() + b":" + dados

    def lista(valor) -> bytes | None:
        if valor is None:
            valor = []
        if not isinstance(valor, list):
            return None
        partes = [texto(v) for v in valor]
        return None if any(p is None for p in partes) else str(len(partes)).encode() + b"[" + b"".join(partes) + b"]"

    campos = [texto(ferramenta), texto(entrada.get("app", "")), lista(entrada.get("to")), lista(entrada.get("cc")),
              texto(entrada.get("subject")), texto(entrada.get("body"))]
    return None if any(c is None for c in campos) else hashlib.sha256(b"\n".join(campos)).hexdigest()


def uid_do_par(sock: socket.socket) -> int | None:
    try:
        if sys.platform.startswith("linux"):
            return struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[1]
        import ctypes
        uid, gid = ctypes.c_uint32(), ctypes.c_uint32()
        if ctypes.CDLL(None, use_errno=True).getpeereid(sock.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0:
            return None
        return uid.value
    except (OSError, AttributeError, ValueError):
        return None


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


def _curto(nome_completo: str) -> str:
    return next((k for k, v in TOOLS.items() if v == nome_completo), "")


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
    def __init__(self, decidir: PedirPermissao | None = None, validade: float = VALIDADE_S, *, uid: int | None = None,
                 bilhete_s: float = BILHETE_S):
        self.decidir, self.validade, self.bilhete_s = decidir, validade, bilhete_s
        self.uid = os.getuid() if uid is None else uid
        self._bilhetes: list[tuple[str, float, float]] = []
        self._cartoes = 0
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

    def autorizar(self, entrada: object, ferramenta: str = "email_send") -> bool:
        marca = huella(ferramenta, entrada) if isinstance(entrada, dict) else None
        if marca is None:
            return False
        self._bilhetes.append((marca, time.monotonic() + self.bilhete_s, time.time() + self.bilhete_s))
        return True

    def _consumir(self, marca: str | None) -> bool:
        agora, relogio = time.monotonic(), time.time()
        self._bilhetes = [b for b in self._bilhetes if b[1] > agora and b[2] > relogio]
        for i, b in enumerate(self._bilhetes):
            if marca is not None and b[0] == marca:
                del self._bilhetes[i]
                return True
        return False

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
            if uid_do_par(writer.get_extra_info("socket")) != self.uid:
                return
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
        if self._consumir(huella(_curto(pedido["tool_name"]), pedido["input"])):
            await self._responder(writer, {"decision": "allow"})
            return
        if self.decidir is None:
            await self._responder(writer, {"decision": "deny", "message": SEM_BILHETE})
            return
        if self._cartoes:
            await self._responder(writer, {"decision": "deny", "message": OCUPADO})
            return
        self._cartoes += 1
        try:
            await self._cartao(reader, writer, pedido)
        finally:
            self._cartoes -= 1

    async def _cartao(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, pedido: dict) -> None:
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
