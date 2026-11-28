import hashlib
import hmac
import json
import socket
import threading

import pytest

from wisp.meetings_win import webhook
from wisp.meetings_win.webhook import (Pending, WebhookApproval, WebhookError, action_items, content, is_public, request_bytes,
                                       section, send, signature, status_code, validate)

NOTE = """---
tipo: reuniao
---
# Plano de lançamento

## Resumo

Combinamos a data do lançamento.
> Resumo ainda não gerado.

## Pontos principais
### Preço
- Você: sugeriu 10% de desconto
### Prazo
- Outros: precisam de duas semanas

## Ações
- [ ] Enviar a proposta — responsável: Você — prazo: 12/05
- [x] Marcar a demo — responsável: não definido — prazo: não definido
- [ ]
Texto solto

## Resumo
Segundo resumo que não conta.

## Transcrição

[0:00] Você: oi
"""


CGNAT = ".".join(("100", "64", "0", "1"))


@pytest.mark.parametrize("url", [
    "https://example.org/hook", "https://hooks.example.org:8443/a/b?x=1", "  https://example.org/a  ",
    "https://203.0.113.1.example.org/x", "https://[2606:4700::1111]/x", "https://1.1.1.1/x"])
def test_public_https_urls_are_accepted(url):
    target = validate(url)
    assert target.host and target.url == url.strip()


@pytest.mark.parametrize("url,message", [
    ("", "não é uma URL válida"), ("not a url", "não é uma URL válida"), ("http://example.org/x", "precisa de um endereço https"),
    ("ftp://example.org", "precisa de um endereço https"), ("https://user:pw@example.org/x", "usuário e senha"),
    ("https://user@example.org/x", "usuário e senha"), ("https://example.org\\@evil.com", "não é uma URL válida"),
    ("https://example.org./x", "não é uma URL válida"), ("https://exa%6Dple.org/x", "não é uma URL válida"),
    ("https://exämple.org/x", "não é uma URL válida"), ("https://example.org/\u0007", "não é uma URL válida"),
    ("https://" + "a" * 2050 + ".org", "não é uma URL válida"), ("https://localhost/x", "local ou privado"),
    ("https://myhost/x", "local ou privado"), ("https://printer.local/x", "local ou privado"),
    ("https://db.internal/x", "local ou privado"), ("https://nas.lan/x", "local ou privado"),
    ("https://a.home/x", "local ou privado"), ("https://a.corp/x", "local ou privado"), ("https://a.test/x", "local ou privado"),
    ("https://a.invalid/x", "local ou privado"), ("https://a.example/x", "local ou privado"),
    ("https://127.0.0.1/x", "local ou privado"), ("https://10.1.2.3/x", "local ou privado"),
    ("https://192.168.0.5/x", "local ou privado"), ("https://172.16.0.1/x", "local ou privado"),
    ("https://169.254.169.254/latest", "local ou privado"), (f"https://{CGNAT}/x", "local ou privado"),
    ("https://224.0.0.1/x", "local ou privado"), ("https://0.0.0.0/x", "local ou privado"),
    ("https://192.0.2.1/x", "local ou privado"), ("https://198.51.100.9/x", "local ou privado"),
    ("https://203.0.113.9/x", "local ou privado"), ("https://198.18.0.1/x", "local ou privado"),
    ("https://2130706433/x", "local ou privado"), ("https://0x7f000001/x", "local ou privado"),
    ("https://127.1/x", "local ou privado"), ("https://0177.0.0.1/x", "local ou privado"),
    ("https://[::1]/x", "local ou privado"), ("https://[fe80::1]/x", "local ou privado"),
    ("https://[fd00::1]/x", "local ou privado"), ("https://[::ffff:127.0.0.1]/x", "local ou privado"),
    ("https://[::ffff:10.0.0.1]/x", "local ou privado"), ("https://[2002:7f00:1::]/x", "local ou privado"),
    ("https://[2001:0:4136:e378::1]/x", "local ou privado"), ("https://[2001:db8::1]/x", "local ou privado")])
def test_everything_else_is_refused_with_a_portuguese_reason(url, message):
    with pytest.raises(WebhookError, match=message):
        validate(url)


def test_public_ipv4_mapped_and_6to4_are_judged_by_the_embedded_address():
    assert is_public("::ffff:8.8.8.8") and is_public("2002:0808:0808::1")
    assert not is_public("::ffff:192.168.1.1") and not is_public("2002:c0a8:0101::")


def test_the_port_defaults_to_443_and_the_target_keeps_path_and_query():
    target = validate("https://example.org:8443/a/b?x=1#frag")
    assert target.port == 8443 and target.request_target == "/a/b?x=1"
    assert validate("https://example.org").port == 443 and validate("https://example.org").request_target == "/"


def test_sections_are_the_first_occurrence_without_quoted_lines():
    assert section("## Resumo", NOTE) == "Combinamos a data do lançamento."
    assert section("## Pontos principais", NOTE).startswith("### Preço")
    assert section("## Não existe", NOTE) == ""


def test_action_items_split_owner_and_due_and_drop_the_undefined():
    assert action_items(NOTE) == [
        {"text": "Enviar a proposta", "owner": "Você", "due": "12/05"}, {"text": "Marcar a demo", "owner": None, "due": None}]


def test_the_body_is_a_whitelist_with_sorted_compact_json():
    metrics = {"duration_s": 60, "you": {"words": 3}, "others": {"words": 1}, "silence_s": 2}
    body, preview = content("Plano", "2026-05-01T13:00:00Z", 60.0, NOTE, metrics)
    data = json.loads(body)
    assert list(data) == sorted(data) and body.count(b" ") == body.decode().count(" ")
    assert set(data) == {"event", "title", "started_at", "duration_s", "overview", "key_points", "action_items", "metrics"}
    assert data["event"] == "meeting.finished" and data["overview"] == "Combinamos a data do lançamento."
    assert "Texto solto" not in body.decode() and "oi" not in data["overview"]
    assert preview == "Combinamos a data do lançamento.\n2 tópico(s) · 2 ação(ões)"
    assert b'": "' not in body and b", " not in body


def test_a_long_overview_is_cut_in_the_preview_only():
    note = "## Resumo\n\n" + "palavra " * 100 + "\n"
    body, preview = content("T", "2026-05-01T13:00:00Z", 1.0, note, None)
    assert len(json.loads(body)["overview"]) > 280 and preview.splitlines()[0].endswith("…") and len(preview.splitlines()[0]) == 281
    assert "metrics" not in json.loads(body)


def pending(signed=False, url="https://example.org:8443/hook?a=b"):
    target = validate(url)
    return Pending(target, b'{"a":1}', "prévia", signed)


def test_the_signature_is_hmac_sha256_over_timestamp_dot_body():
    expected = hmac.new(b"segredo", b"1700000000." + b'{"a":1}', hashlib.sha256).hexdigest()
    assert signature(b'{"a":1}', "segredo", 1700000000) == "sha256=" + expected


def test_the_request_is_hand_written_with_connection_close_and_the_signing_headers():
    raw = request_bytes(pending(True), "segredo", 1700000000).decode()
    head, _, body = raw.partition("\r\n\r\n")
    lines = head.split("\r\n")
    assert lines[0] == "POST /hook?a=b HTTP/1.1" and "Host: example.org:8443" in lines
    assert "Content-Type: application/json" in lines and "Content-Length: 7" in lines
    assert "User-Agent: Wisp" in lines and "Connection: close" in lines
    assert "X-Wisp-Timestamp: 1700000000" in lines
    assert any(l == "X-Wisp-Signature: " + signature(b'{"a":1}', "segredo", 1700000000) for l in lines)
    assert body == '{"a":1}'
    plain = request_bytes(pending(False, "https://example.org/hook"), None, 1).decode()
    assert "Host: example.org\r\n" in plain and "X-Wisp" not in plain


def test_a_signed_request_without_its_secret_is_not_built():
    assert request_bytes(pending(True), None, 1) is None


def test_status_codes_come_from_the_first_line_only():
    assert status_code(b"HTTP/1.1 204 No Content\r\n\r\n") == 204
    assert status_code(b"HTTP/1.0 301 Moved\r\nLocation: x\r\n\r\n") == 301
    assert status_code(b"garbage") is None and status_code(b"HTTP/2 200 OK\r\n") is None and status_code(b"HTTP/1.1 20 x\r\n") is None


def test_the_card_text_masks_the_path_and_shows_size_and_both_body_forms():
    card = pending()
    assert card.masked_url == "https://example.org:8443/•••" and pending(url="https://example.org/").masked_url == "https://example.org"
    assert card.size_text == "7 B" and Pending(card.target, b"x" * 2048, "", False).size_text == "2.0 KB"
    assert card.body_text == '{"a":1}' and card.formatted_body_text == '{\n  "a": 1\n}'


def test_approval_holds_one_offer_per_meeting_and_hands_it_over_once():
    approval = WebhookApproval()
    offer = pending()
    approval.offer(offer, "m1")
    assert approval.approve("m1") is offer and approval.approve("m1") is None
    approval.offer(offer, "m2")
    approval.dismiss("m2")
    assert approval.approve("m2") is None


class Posted:
    def __init__(self, outcomes):
        self.outcomes, self.calls = list(outcomes), []

    def __call__(self, host, address, port, request):
        self.calls.append(address)
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


def test_send_posts_to_the_resolved_public_address_and_reports_success():
    posted = Posted([200])
    send(pending(), None, resolver=lambda host, port: ["93.184.216.34"], post=posted, now=lambda: 5)
    assert posted.calls == ["93.184.216.34"]


def test_a_host_that_resolves_to_a_private_address_is_refused_before_any_connection():
    posted = Posted([200])
    with pytest.raises(WebhookError, match="aponta para um endereço local ou privado"):
        send(pending(), None, resolver=lambda host, port: ["93.184.216.34", "10.0.0.5"], post=posted)
    assert posted.calls == []


def test_the_next_address_is_tried_only_when_nothing_was_handed_over():
    posted = Posted([webhook.NotSent("sem rota"), 204])
    send(pending(), None, resolver=lambda host, port: ["93.184.216.34", "93.184.216.35"], post=posted)
    assert posted.calls == ["93.184.216.34", "93.184.216.35"]
    posted = Posted([webhook.HandedOver("timeout"), 200])
    with pytest.raises(WebhookError, match="pode ter chegado"):
        send(pending(), None, resolver=lambda host, port: ["93.184.216.34", "93.184.216.35"], post=posted)
    assert posted.calls == ["93.184.216.34"]


def test_redirects_and_error_statuses_stop_the_send():
    for code, message in ((302, "redirecionar"), (500, "respondeu 500"), (404, "respondeu 404")):
        with pytest.raises(WebhookError, match=message):
            send(pending(), None, resolver=lambda h, p: ["93.184.216.34", "93.184.216.35"], post=Posted([code, 200]))


def test_a_signed_send_reads_the_secret_at_send_time_and_refuses_without_it():
    seen = []

    def post(host, address, port, request):
        seen.append(request)
        return 200

    send(pending(True), "segredo", resolver=lambda h, p: ["93.184.216.34"], post=post, now=lambda: 1700000000)
    assert b"X-Wisp-Signature: sha256=" in seen[0]
    with pytest.raises(WebhookError, match="não consegui montar o pedido"):
        send(pending(True), None, resolver=lambda h, p: ["93.184.216.34"], post=post)


def test_the_real_socket_path_connects_to_the_pinned_address_and_parses_the_answer():
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    received = []

    def serve():
        conn, _ = server.accept()
        data = b""
        while b"\r\n\r\n" not in data:
            data += conn.recv(4096)
        received.append(data)
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        conn.close()

    threading.Thread(target=serve, daemon=True).start()
    code = webhook.pinned_post("example.org", "127.0.0.1", port, b"POST / HTTP/1.1\r\nHost: example.org\r\n\r\n",
                               timeout=5, wrap=lambda sock, host: sock)
    assert code == 200 and received[0].startswith(b"POST / HTTP/1.1")
    server.close()


def test_a_closed_port_fails_before_the_request_is_handed_over():
    free = socket.socket()
    free.bind(("127.0.0.1", 0))
    port = free.getsockname()[1]
    free.close()
    with pytest.raises(webhook.NotSent):
        webhook.pinned_post("example.org", "127.0.0.1", port, b"x", timeout=2, wrap=lambda sock, host: sock)
