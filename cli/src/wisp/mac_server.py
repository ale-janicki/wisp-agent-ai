import asyncio
import inspect
import os
from collections.abc import Callable
from typing import Annotated

from mcp.server.mcpserver import MCPServer
from mcp.types import CallToolResult, TextContent
from pydantic import Field

from wisp.mac import Falha
from wisp.mac_control import TOOLS, Ctx, Tool, call
from wisp.paths import WispPaths
from wisp.runner import SubprocessRunner
from wisp.send_gate import Gate, gate_from_env

SERVER_NAME = "wisp-mac"
TOOL_NAME = "mac_send"
PYTHON_TYPES = {"string": str, "integer": int, "array": list[str]}


def _result(text: str, *, error: bool = False) -> CallToolResult:
    return CallToolResult(content=[TextContent(type="text", text=text)], is_error=error)


def _signature(tool: Tool) -> inspect.Signature:
    params = []
    for name, spec in tool.properties.items():
        kind = Annotated[PYTHON_TYPES[spec["type"]], Field(description=spec["description"])]
        required = name in tool.required
        params.append(inspect.Parameter(name, inspect.Parameter.KEYWORD_ONLY, default=inspect.Parameter.empty if required else None,
                                        annotation=kind if required else kind | None))
    params.sort(key=lambda p: p.default is not inspect.Parameter.empty)
    return inspect.Signature(params, return_annotation=CallToolResult)


def _handler(ctx: Ctx, tool: Tool) -> Callable:
    async def run(**arguments) -> CallToolResult:
        given = {k: v for k, v in arguments.items() if v is not None}
        try:
            return _result(await asyncio.to_thread(call, ctx, tool.name, given))
        except Falha as e:
            return _result(str(e), error=True)

    run.__signature__ = _signature(tool)
    run.__name__ = tool.name
    return run


def build_server(ctx: Ctx) -> MCPServer:
    server = MCPServer(SERVER_NAME)
    for tool in TOOLS.values():
        server.add_tool(_handler(ctx, tool), name=tool.name, description=tool.description)
    return server


def run_server() -> None:
    gate: Gate = gate_from_env(os.environ, TOOL_NAME)
    build_server(Ctx(SubprocessRunner(), WispPaths.current(), gate=gate)).run("stdio")
