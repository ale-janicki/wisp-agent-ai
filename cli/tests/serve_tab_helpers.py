import json
import os

import httpx
from starlette.testclient import TestClient

from wisp.serve.app import create_app

os.environ.setdefault("WISP_CLIPBOARD_POLL", "0")

TOKEN = "t0ken-for-tests"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class XorProtector:
    def protect(self, data: bytes) -> bytes:
        return bytes(b ^ 0x5A for b in data)

    unprotect = protect


def client() -> TestClient:
    return TestClient(create_app(TOKEN), headers=AUTH)


def mock_http(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def json_response(body, status: int = 200, headers: dict | None = None) -> httpx.Response:
    return httpx.Response(status, content=json.dumps(body).encode(), headers=headers)


def host_of(test_client: TestClient):
    return test_client.app.app.app.state.host
