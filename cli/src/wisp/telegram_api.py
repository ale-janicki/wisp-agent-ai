import http.client
import json
import urllib.error
import urllib.request

DEFAULT_BASE = "https://api.telegram.org"
ALLOWED = ["message"]


class TelegramError(Exception):
    """One plain sentence, never carrying the token or the request URL."""


class TelegramAPI:
    def __init__(self, token: str, base: str = DEFAULT_BASE):
        self._root = f"{base.rstrip('/')}/bot{token}"
        self._offset: int | None = None

    def _call(self, method: str, params: dict, timeout: float) -> object:
        body = json.dumps(params).encode()
        request = urllib.request.Request(
            f"{self._root}/{method}", data=body, headers={"Content-Type": "application/json"}
        )
        payload = None
        unreachable = False
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = json.load(response)
        except urllib.error.HTTPError as e:
            payload = _error_body(e)
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
            unreachable = True
        if unreachable:   # raised outside the except block so no traceback chain holds the URL
            raise TelegramError("não consegui falar com o Telegram; confira a internet")
        if not isinstance(payload, dict) or not payload.get("ok"):
            description = payload.get("description") if isinstance(payload, dict) else None
            raise TelegramError(f"o Telegram recusou o pedido: {description or 'resposta inesperada'}")
        return payload["result"]

    def get_me(self) -> dict:
        return self._call("getMe", {}, 15)

    def get_updates(self, timeout: int) -> list[dict]:
        params: dict = {"timeout": timeout, "allowed_updates": ALLOWED}
        if self._offset is not None:
            params["offset"] = self._offset
        updates = self._call("getUpdates", params, timeout + 10)
        if updates:
            self._offset = max(u["update_id"] for u in updates) + 1
        return updates

    def get_chat(self, chat_id: int) -> dict:
        return self._call("getChat", {"chat_id": chat_id}, 15)

    def get_chat_member(self, chat_id: int, user_id: int) -> dict:
        return self._call("getChatMember", {"chat_id": chat_id, "user_id": user_id}, 15)


def _error_body(error: urllib.error.HTTPError) -> object:
    try:
        return json.load(error)
    except (OSError, http.client.HTTPException, ValueError):
        return None
