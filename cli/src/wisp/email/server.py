"""Email as an MCP tool for every engine; sending waits for the user's approval."""

import json
import os
from collections.abc import Awaitable, Callable
from dataclasses import asdict

import anyio.to_thread
from mcp.server.mcpserver import MCPServer
from mcp.types import CallToolResult, TextContent

from wisp import approvals
from wisp.approvals import ApprovalDirError, Outcome
from wisp.email.mail_app import MailApp, MailError
from wisp.paths import WispPaths

SERVER_NAME = "wisp-email"
SENT = "enviado"
DENIED = "o usuário negou o envio"
NOBODY = "não enviado: ninguém aprovou"
NO_CHANNEL = "não enviado: o canal de aprovação não está seguro"

Request = Callable[..., Awaitable[Outcome]]


class ToolFailure(Exception):
    """str() is the sentence the assistant reads, delivered with isError true."""


def _guard(call: Callable):
    try:
        return call()
    except MailError as e:
        raise ToolFailure(str(e)) from None


def email_list(mail: MailApp, mailbox: str = "INBOX", limit: int = 20) -> list[dict]:
    return [asdict(m) for m in _guard(lambda: mail.list(mailbox, limit))]


def email_read(mail: MailApp, id: str) -> dict:
    return asdict(_guard(lambda: mail.read(id)))


def email_search(mail: MailApp, query: str, limit: int = 20) -> list[dict]:
    return [asdict(m) for m in _guard(lambda: mail.search(query, limit))]


async def email_send(
    mail: MailApp,
    request: Request,
    paths: WispPaths,
    to: list[str],
    subject: str,
    body: str,
    cc: list[str] | None = None,
    thread: int | None = None,
) -> str:
    cc = cc or []
    detail = f"Para: {', '.join(to)}\nCc: {', '.join(cc)}\nAssunto: {subject}\n\n{body}"
    async def send() -> None:
        await anyio.to_thread.run_sync(lambda: _guard(lambda: mail.send(to, subject, body, cc)))

    try:
        outcome = await request(paths, "email_send", f"enviar e-mail para {', '.join(to)}: {subject}", detail, thread=thread, act=send)
    except ApprovalDirError:
        raise ToolFailure(NO_CHANNEL) from None
    if outcome == "deny":
        return DENIED
    if outcome != "allow":
        return NOBODY
    return SENT


def _thread_from_env() -> int | None:
    try:
        return int(os.environ["WISP_TELEGRAM_THREAD"])
    except (KeyError, ValueError):
        return None


def _failure(e: ToolFailure) -> CallToolResult:
    return CallToolResult(content=[TextContent(type="text", text=str(e))], is_error=True)


def _text(value) -> CallToolResult:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return CallToolResult(content=[TextContent(type="text", text=text)])


def _reply(call: Callable) -> CallToolResult:
    try:
        return _text(call())
    except ToolFailure as e:
        return _failure(e)


def build_server(mail: MailApp, request: Request, paths: WispPaths | None, thread: int | None) -> MCPServer:
    server = MCPServer(SERVER_NAME)

    @server.tool(name="email_list", description="Lista os e-mails mais recentes de uma caixa do Mail (padrão INBOX)")
    def _list(mailbox: str = "INBOX", limit: int = 20) -> CallToolResult:
        return _reply(lambda: email_list(mail, mailbox, limit))

    @server.tool(name="email_read", description="Lê um e-mail pelo id devolvido por email_list ou email_search")
    def _read(id: str) -> CallToolResult:
        return _reply(lambda: email_read(mail, id))

    @server.tool(name="email_search", description="Busca e-mails por assunto ou remetente em todas as caixas")
    def _search(query: str, limit: int = 20) -> CallToolResult:
        return _reply(lambda: email_search(mail, query, limit))

    @server.tool(name="email_send", description="Envia um e-mail; o usuário precisa aprovar antes de sair")
    async def _send(to: list[str], subject: str, body: str, cc: list[str] | None = None) -> CallToolResult:
        # Async on purpose: a cancelled call or a closed stdin cancels this task at the poll sleep and
        # the approval request is withdrawn; a sync tool would sit in a worker thread for up to 600 s.
        try:
            return _text(await email_send(mail, request, paths, to, subject, body, cc, thread))
        except ToolFailure as e:
            return _failure(e)

    return server


def run_server(mail: MailApp, paths: WispPaths) -> None:
    build_server(mail, approvals.request_async, paths, _thread_from_env()).run("stdio")
