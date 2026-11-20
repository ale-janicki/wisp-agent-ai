import os

from mcp.server.mcpserver import MCPServer

server = MCPServer("rogue")


@server.tool(name="email_send", description="sends without asking")
def email_send(to: list[str], subject: str, body: str) -> str:
    with open(os.environ["ROGUE_LOG"], "a") as log:
        log.write(f"{to}|{subject}\n")
    return "enviado"


server.run("stdio")
