import struct
import zlib

import pytest

from serve_tab_helpers import client, host_of
from wisp.serve.features import clipboard as clipboard_tab
from wisp.serve.features.clipboard import images
from wisp.serve.features.clipboard.service import Clipboard, ClipboardBusy
from wisp.serve.features.clipboard.store import (CAPACITY, ClipboardStore, ClipItem, History, REFERENCE_EPOCH, fingerprint,
                                                 kind_of, should_capture)


def item(text, at=1_000_000.0, pinned=False, kind="text"):
    made = ClipItem.new(kind, text, None, fingerprint(text.encode()), at)
    made.pinned = pinned
    return made


class FakeSource:
    def __init__(self):
        self.seq, self.types, self.text, self.image, self.written = 1, ["Text"], None, None, []
        self.flags, self.busy = {}, 0

    def copy(self, text=None, image=None, types=("Text",)):
        self.seq += 1
        self.text, self.image, self.types = text, image, list(types)

    def sequence(self):
        return self.seq

    def formats(self):
        if self.busy:
            self.busy -= 1
            raise ClipboardBusy("em uso")
        return self.types

    def read_flag(self, name):
        return self.flags.get(name)

    def read_text(self):
        return self.text

    def read_image(self):
        return self.image

    def write_text(self, text):
        self.written.append(("text", text))
        self.seq += 1

    def write_image(self, png):
        self.written.append(("image", png))
        self.seq += 1


def dib(width, height, pixel=(10, 20, 30), bits=24, top_down=False):
    pixel_bytes = bytes(reversed(pixel)) + (b"\x00" if bits == 32 else b"")
    stride = (width * bits + 31) // 32 * 4
    row = (pixel_bytes * width).ljust(stride, b"\x00")
    header = struct.pack("<IiiHHIIiiII", 40, width, -height if top_down else height, 1, bits, 0, len(row) * height, 0, 0, 0, 0)
    return header + row * height


def make(tmp_path, source=None, now=lambda: 2_000_000.0):
    return Clipboard(ClipboardStore(tmp_path / "clip"), source, clock=now)


def test_copying_the_same_text_again_moves_it_up_keeping_its_pin():
    history = History([item("b"), item("a", pinned=True)])
    history.insert(item("a", at=5.0))
    assert [i.text for i in history.items] == ["a", "b"] and history.items[0].pinned and history.items[0].copied_at == 5.0


def test_eviction_never_drops_a_pinned_item():
    history = History([item(f"n{n}") for n in range(CAPACITY)])
    history.items[-1].pinned = True
    evicted = history.insert(item("new"))
    assert len(history.items) == CAPACITY and [e.text for e in evicted] == [f"n{CAPACITY - 2}"]
    assert history.items[-1].pinned


def test_expire_keeps_pinned_and_recent_items():
    history = History([item("old", at=0), item("pinned old", at=0, pinned=True), item("fresh", at=90_000)])
    removed = history.expire(now=100_000)
    assert [r.text for r in removed] == ["old"] and [i.text for i in history.items] == ["pinned old", "fresh"]


def test_search_ignores_case_and_accents_and_lists_pinned_first():
    history = History([item("Reunião de HOJE"), item("outra coisa"), item("reuniao antiga", pinned=True)])
    assert [i.text for i in history.visible("reuniao")] == ["reuniao antiga", "Reunião de HOJE"]
    assert len(history.visible("  ")) == 3


def test_kind_detects_a_single_http_link_only():
    assert kind_of("https://exemplo.com/a b") == "text"
    assert kind_of(" https://exemplo.com/a ") == "url"
    assert kind_of("ftp://x.com") == "text" and kind_of("exemplo.com") == "text"


def test_concealed_and_password_manager_formats_are_never_captured():
    assert should_capture(["Text"]) and not should_capture([])
    assert not should_capture(["Text", "ExcludeClipboardContentFromMonitorProcessing"])
    assert not should_capture(["org.nspasteboard.ConcealedType"])


def test_history_file_is_the_macs_encoding(tmp_path):
    store = ClipboardStore(tmp_path)
    one = ClipItem("0A1B2C3D-0000-4000-8000-000000000001", "url", "https://a.com/x", None, "ff", REFERENCE_EPOCH + 12.5, True)
    two = ClipItem("0A1B2C3D-0000-4000-8000-000000000002", "image", None, "X.png", "ee", REFERENCE_EPOCH + 3)
    store.save(History([one, two]))
    assert store.file.read_text("utf-8") == (
        '{"items":[{"copiedAt":12.5,"fingerprint":"ff","id":"0A1B2C3D-0000-4000-8000-000000000001","kind":"url",'
        '"pinned":true,"text":"https:\\/\\/a.com\\/x"},{"copiedAt":3,"fingerprint":"ee",'
        '"id":"0A1B2C3D-0000-4000-8000-000000000002","image":"X.png","kind":"image","pinned":false}]}')
    assert store.load().items == [one, two]


def test_a_history_written_by_the_mac_loads(tmp_path):
    (tmp_path / "history.json").write_text('{"items":[{"copiedAt":770000000.25,"fingerprint":"ab","id":"AB","kind":"text","pinned":false,"text":"oi"}]}')
    loaded = ClipboardStore(tmp_path).load().items[0]
    assert loaded.text == "oi" and loaded.copied_at == 770000000.25 + REFERENCE_EPOCH


def test_a_corrupt_history_is_set_aside_and_reported(tmp_path):
    store = ClipboardStore(tmp_path)
    (tmp_path / "history.json").write_text("{not json")
    assert store.load().items == [] and (tmp_path / "history.json.bad").exists() and not store.file.exists()
    assert "corrompido" in store.last_recovery_note


def test_image_files_are_found_by_plain_name_only(tmp_path):
    store = ClipboardStore(tmp_path)
    assert store.path_of("../x.png") is None and store.path_of(".history") is None and store.path_of("A.png") == tmp_path / "A.png"


def png_size(data):
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    return struct.unpack(">II", data[16:24])


def test_a_dib_becomes_a_valid_png_and_a_small_thumbnail():
    png, thumb = images.encode(dib(400, 200, (255, 0, 0)))
    assert png_size(png) == (400, 200) and png_size(thumb) == (160, 80)
    idat = png[png.index(b"IDAT") + 4:png.index(b"IEND") - 8]
    raw = zlib.decompress(idat)
    assert raw[:4] == b"\x00\xff\x00\x00"


def test_dib_orientation_and_32_bit_pixels_read_back():
    for bits in (24, 32):
        for top_down in (False, True):
            rows = images.decode_dib(dib(2, 2, (1, 2, 3), bits, top_down))[2]
            assert rows == [b"\x01\x02\x03" * 2] * 2
    assert images.decode_dib(b"short") is None and images.encode(b"not an image at all, not even close!!!!!!!!!!") is None


def test_a_png_on_the_clipboard_is_kept_as_is():
    png = images.encode_png(1, 1, [b"\x01\x02\x03"])
    assert images.encode(png) == (png, png)


def test_a_copied_text_is_stored_and_the_same_text_is_not_duplicated(tmp_path):
    source = FakeSource()
    board = make(tmp_path, source)
    assert board.tick() is False
    source.copy("olá mundo")
    assert board.tick() is True and board.tick() is False
    source.copy("olá mundo")
    board.tick()
    assert [i.text for i in board.items()] == ["olá mundo"]
    assert ClipboardStore(tmp_path / "clip").load().items[0].kind == "text"


def test_a_copied_link_is_a_url_item(tmp_path):
    source = FakeSource()
    board = make(tmp_path, source)
    source.copy("https://wisp.example/a")
    board.tick()
    assert board.items()[0].kind == "url"


def test_private_copies_and_oversized_text_are_skipped(tmp_path):
    source = FakeSource()
    board = make(tmp_path, source)
    source.copy("senha", types=["Text", "ExcludeClipboardContentFromMonitorProcessing"])
    board.tick()
    source.copy("x" * 1_000_001)
    board.tick()
    source.copy("   ")
    board.tick()
    assert board.items() == []


def test_capture_can_be_turned_off(tmp_path):
    source = FakeSource()
    board = make(tmp_path, source)
    assert board.capture_enabled
    board.set_capture(False)
    source.copy("não guardar")
    board.tick()
    assert board.items() == [] and not make(tmp_path, source).capture_enabled


def test_a_copied_image_writes_the_png_and_its_thumbnail(tmp_path):
    source = FakeSource()
    board = make(tmp_path, source)
    source.copy(image=dib(300, 300), types=["CF_DIB"])
    board.tick()
    found = board.items()[0]
    assert found.kind == "image" and found.text is None
    assert png_size((tmp_path / "clip" / found.image).read_bytes()) == (300, 300)
    assert png_size((tmp_path / "clip" / found.image.replace(".png", "-thumb.png")).read_bytes()) == (160, 160)
    board.remove(found.id)
    assert not (tmp_path / "clip" / found.image).exists()


def test_copy_back_writes_the_clipboard_and_moves_the_item_to_the_top(tmp_path):
    source = FakeSource()
    now = [100.0]
    board = make(tmp_path, source, now=lambda: now[0])
    source.copy("primeiro")
    board.tick()
    now[0] = 200.0
    source.copy("segundo")
    board.tick()
    now[0] = 300.0
    first = board.items()[1]
    assert board.copy(first) is True
    assert source.written == [("text", "primeiro")]
    assert [i.text for i in board.items()] == ["primeiro", "segundo"] and board.items()[0].copied_at == 300.0
    assert board.tick() is False


def test_pin_remove_and_clear_keep_pinned_items(tmp_path):
    source = FakeSource()
    board = make(tmp_path, source)
    for text in ("a", "b", "c"):
        source.copy(text)
        board.tick()
    board.toggle_pin(board.find(board.items()[2].id).id)
    board.clear_unpinned()
    assert [i.text for i in board.items()] == ["a"] and board.items()[0].pinned


def test_a_sweep_drops_what_is_older_than_a_day(tmp_path):
    now = [0.0]
    source = FakeSource()
    board = make(tmp_path, source, now=lambda: now[0])
    source.copy("velho")
    board.tick()
    now[0] = 90_000.0
    board.tick()
    assert board.items() == []


@pytest.fixture
def served(tmp_path, monkeypatch):
    source = FakeSource()
    board = make(tmp_path, source)
    monkeypatch.setattr(clipboard_tab, "_clipboard", board)
    return board, source


def test_items_route_lists_searches_and_explains_empty_states(served):
    board, source = served
    c = client()
    assert c.get("/api/clipboard/items").json()["empty"] == "Nada copiado ainda"
    source.copy("Reunião")
    board.tick()
    got = c.get("/api/clipboard/items", params={"q": "reuniao"}).json()
    assert [i["text"] for i in got["items"]] == ["Reunião"] and got["empty"] is None and got["capture"] is True
    assert c.get("/api/clipboard/items", params={"q": "zzz"}).json()["empty"] == "Nada encontrado"


def test_actions_over_http_and_the_changed_event(served):
    board, source = served
    c = client()
    source.copy("um")
    board.tick()
    ident = c.get("/api/clipboard/items").json()["items"][0]["id"]
    queue = host_of(c).hub.subscribe()
    assert c.post(f"/api/clipboard/items/{ident}/pin").json() == {"ok": True}
    assert queue.get_nowait() == {"feature": "clipboard", "type": "changed"}
    assert c.get("/api/clipboard/items").json()["items"][0]["pinned"] is True
    assert c.post(f"/api/clipboard/items/{ident}/copy").json() == {"ok": True} and source.written == [("text", "um")]
    assert c.put("/api/clipboard/capture", json={"enabled": False}).json() == {"capture": False}
    assert c.put("/api/clipboard/capture", json={"enabled": "no"}).status_code == 400
    assert c.post("/api/clipboard/clear").json() == {"ok": True} and board.total() == 1
    assert c.delete(f"/api/clipboard/items/{ident}").json() == {"ok": True}
    assert c.delete(f"/api/clipboard/items/{ident}").status_code == 404
    assert c.post("/api/clipboard/items/NOPE/copy").status_code == 404


def test_thumbnail_route_serves_the_png_as_a_data_url(served):
    import base64
    board, source = served
    source.copy(image=dib(200, 100), types=["CF_DIB"])
    board.tick()
    found = board.items()[0]
    got = client().get(f"/api/clipboard/items/{found.id}/thumbnail")
    assert got.status_code == 200
    assert png_size(base64.b64decode(got.json()["data_url"].removeprefix("data:image/png;base64,"))) == (160, 80)
    assert client().get("/api/clipboard/items/NOPE/thumbnail").status_code == 404


def test_the_poller_thread_can_wake_the_event_stream():
    import asyncio
    import threading

    from wisp.serve.app import Hub

    class Host:
        hub = Hub()

        def publish_feature(self, feature, type_):
            self.hub.publish({"feature": feature, "type": type_})

    async def scenario():
        host = Host()
        queue = host.hub.subscribe()
        notify = clipboard_tab.notifier(host, asyncio.get_running_loop())
        threading.Thread(target=notify).start()
        return await asyncio.wait_for(queue.get(), 2)

    assert asyncio.run(scenario()) == {"feature": "clipboard", "type": "changed"}


@pytest.mark.parametrize("flag", ["CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"])
def test_a_zero_windows_privacy_flag_keeps_the_copy_out_of_the_history(tmp_path, flag):
    source = FakeSource()
    board = make(tmp_path, source)
    source.copy("senha do banco", types=["Text", flag])
    source.flags[flag] = 0
    board.tick()
    assert board.items() == [] and not board.store.file.exists()
    source.copy("copia normal", types=["Text", flag])
    source.flags[flag] = 1
    board.tick()
    assert [i.text for i in board.items()] == ["copia normal"]


def test_a_flag_that_is_absent_or_unreadable_does_not_block_a_copy(tmp_path):
    source = FakeSource()
    board = make(tmp_path, source)
    source.copy("oi", types=["Text", "CanIncludeInClipboardHistory"])
    board.tick()
    assert [i.text for i in board.items()] == ["oi"]


def test_a_busy_clipboard_is_retried_on_the_next_tick(tmp_path):
    source = FakeSource()
    board = make(tmp_path, source)
    source.copy("não perder")
    source.busy = 2
    assert board.tick() is False and board.items() == []
    assert board.tick() is False and board.items() == []
    assert board.tick() is True and [i.text for i in board.items()] == ["não perder"]
    assert board.tick() is False


def test_a_skipped_copy_is_not_read_again(tmp_path):
    source = FakeSource()
    board = make(tmp_path, source)
    source.copy("x", types=["ExcludeClipboardContentFromMonitorProcessing"])
    board.tick()
    source.types = ["Text"]
    assert board.tick() is False and board.items() == []


def test_the_poller_starts_from_the_startup_hook_not_from_import(monkeypatch, tmp_path):
    started = []
    monkeypatch.setattr(clipboard_tab, "_clipboard", None)
    monkeypatch.setattr(clipboard_tab, "_source", lambda: FakeSource())
    monkeypatch.setattr(clipboard_tab, "ClipboardStore", lambda: ClipboardStore(tmp_path / "clip"))
    monkeypatch.setenv("WISP_CLIPBOARD_POLL", "1")
    monkeypatch.setattr(clipboard_tab, "_start_thread", lambda board, stop: started.append(board))
    assert clipboard_tab._clipboard is None
    stop = clipboard_tab.startup(object())
    assert len(started) == 1 and callable(stop)
    stop()


def test_tests_can_switch_the_poller_off_explicitly(monkeypatch):
    monkeypatch.setattr(clipboard_tab, "_clipboard", None)
    monkeypatch.setenv("WISP_CLIPBOARD_POLL", "0")
    monkeypatch.setattr(clipboard_tab, "_start_thread", lambda *a: pytest.fail("poller started"))
    assert clipboard_tab.startup(object()) is None


def test_the_app_calls_every_feature_startup_and_stops_it_on_shutdown(monkeypatch):
    calls = []
    monkeypatch.setattr(clipboard_tab, "startup", lambda host: (calls.append("up"), lambda: calls.append("down"))[1])
    with client():
        assert calls == ["up"]
    assert calls == ["up", "down"]
