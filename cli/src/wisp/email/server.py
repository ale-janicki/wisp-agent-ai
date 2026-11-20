"""Email as an MCP tool for every engine. Sending is approved by Claude Code's own permission prompt (an `ask` rule on
mcp__wisp-email__email_send), never by this process: the prompt is a channel the agent cannot answer."""

import json
from collections.abc import Callable
from dataclasses import asdict

from mcp.server.mcpserver import MCPServer
from mcp.types import CallToolResult, TextContent

from wisp.email.mail_app import MailApp, MailError, check_recipients

SERVER_NAME = "wisp-email"
SENT = "enviado"


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


def email_send(mail: MailApp, to: list[str], subject: str, body: str, cc: list[str] | None = None) -> str:
    cc = cc or []
    _guard(lambda: check_recipients(to, cc))
    _guard(lambda: mail.send(to, subject, body, cc))
    return SENT


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


def build_server(mail: MailApp) -> MCPServer:
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

    @server.tool(name="email_send", description="Envia um e-mail; o Claude Code pede a aprovação do usuário antes de sair")
    def _send(to: list[str], subject: str, body: str, cc: list[str] | None = None) -> CallToolResult:
        return _reply(lambda: email_send(mail, to, subject, body, cc))

    return server


def run_server(mail: MailApp) -> None:
    build_server(mail).run("stdio")
