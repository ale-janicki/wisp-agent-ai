from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

import uvicorn

from wisp.serve.app import create_app


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="wisp-serve", description="Local HTTP/SSE sidecar for the Wisp chat.")
    parser.add_argument("--port", type=int, default=0, help="TCP port on 127.0.0.1 (0 = pick a free one)")
    args = parser.parse_args(argv)
    token = os.environ.get("WISP_SERVE_TOKEN", "")
    if not token:
        print("wisp-serve: WISP_SERVE_TOKEN is required", file=sys.stderr)
        return 2
    config = uvicorn.Config(create_app(token), host="127.0.0.1", port=args.port, log_level="warning",
                            access_log=False, timeout_graceful_shutdown=3)
    server = uvicorn.Server(config)

    async def run() -> None:
        task = asyncio.create_task(server.serve())
        while not server.started and not task.done():
            await asyncio.sleep(0.02)
        if server.started:
            port = server.servers[0].sockets[0].getsockname()[1]
            print(json.dumps({"ready": True, "port": port}), flush=True)
        await task

    asyncio.run(run())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
