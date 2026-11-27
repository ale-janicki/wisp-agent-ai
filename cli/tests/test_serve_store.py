import json
import threading
from datetime import datetime, timezone

from wisp.serve.store import ConversationStore, TranscriptStore, data_dir, title_fallback

MAC_CONVERSATIONS = """[
  {
    "awayOnPhone" : false,
    "cwd" : "\\/srv\\/wisp",
    "id" : "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
    "lastFrom" : "agent",
    "lastPreview" : "ok",
    "sessionId" : "99f6caac-8493-4246-9c13-04c5e4262742",
    "title" : "Conversa A",
    "titleGenerated" : true,
    "updatedAt" : "2026-02-01T10:00:00.250Z"
  },
  {
    "id" : "11111111-2222-3333-4444-555555555555",
    "title" : "Velha",
    "updatedAt" : "2026-01-01T00:00:00Z"
  }
]"""


def test_reads_mac_conversations_json_newest_first(tmp_path):
    (tmp_path / "conversations.json").write_text(MAC_CONVERSATIONS, encoding="utf-8")
    store = ConversationStore(tmp_path)
    items = store.all()
    assert [r["title"] for r in items] == ["Conversa A", "Velha"]
    assert items[0]["sessionId"] == "99f6caac-8493-4246-9c13-04c5e4262742"
    assert items[0]["cwd"] == "/srv/wisp"


def test_upsert_round_trip_keeps_mac_field_names_and_unknown_fields(tmp_path):
    (tmp_path / "conversations.json").write_text(MAC_CONVERSATIONS, encoding="utf-8")
    store = ConversationStore(tmp_path)
    record = store.get("e621e1f8-c36c-495a-93fc-0c247a3e6e5f")
    assert record["id"] == "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
    record["title"] = "Renomeada"
    record["updatedAt"] = datetime(2026, 3, 1, 12, 0, 0, 500000, tzinfo=timezone.utc)
    store.upsert(record)
    raw = json.loads((tmp_path / "conversations.json").read_text(encoding="utf-8"))
    assert [r["title"] for r in raw] == ["Renomeada", "Velha"]
    assert raw[0]["updatedAt"] == "2026-03-01T12:00:00.500Z"
    assert raw[0]["lastFrom"] == "agent" and raw[0]["titleGenerated"] is True
    assert "closedAt" not in raw[0]
    assert ConversationStore(tmp_path).all()[0]["title"] == "Renomeada"


def test_create_writes_uppercase_uuid_and_default_title(tmp_path):
    store = ConversationStore(tmp_path)
    record = store.create("Meu chat")
    raw = json.loads((tmp_path / "conversations.json").read_text(encoding="utf-8"))
    assert raw[0]["id"] == record["id"] == record["id"].upper()
    assert len(record["id"]) == 36
    assert raw[0]["title"] == "Meu chat"
    assert store.create(None)["title"] == "Nova conversa"


def test_delete_and_lock_file_beside_the_index(tmp_path):
    store = ConversationStore(tmp_path)
    keep, gone = store.create("keep"), store.create("gone")
    store.delete(gone["id"])
    assert [r["title"] for r in store.all()] == ["keep"]
    assert (tmp_path / "conversations.json.lock").exists()
    assert keep["id"] in {r["id"] for r in store.all()}


def test_corrupt_index_is_moved_aside(tmp_path):
    (tmp_path / "conversations.json").write_text("{not json", encoding="utf-8")
    store = ConversationStore(tmp_path)
    assert store.all() == []
    assert (tmp_path / "conversations.json.bad").read_text(encoding="utf-8") == "{not json"
    assert store.last_recovery_note


def test_two_stores_see_each_others_writes(tmp_path):
    a, b = ConversationStore(tmp_path), ConversationStore(tmp_path)
    a.create("from a")
    assert [r["title"] for r in b.all()] == ["from a"]
    b.create("from b")
    assert {r["title"] for r in a.all()} == {"from a", "from b"}


def test_concurrent_upserts_lose_nothing(tmp_path):
    def work(n):
        store = ConversationStore(tmp_path)
        for i in range(5):
            store.create(f"c{n}-{i}")

    threads = [threading.Thread(target=work, args=(n,)) for n in range(4)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert len(ConversationStore(tmp_path).all()) == 20


def test_title_fallback_like_the_mac():
    assert title_fallback("  olá   mundo ") == "olá mundo"
    assert title_fallback("a" * 40) == "a" * 32
    assert title_fallback("palavra " * 10) == "palavra palavra palavra palavra"


def test_transcript_lines_have_the_mac_encoding(tmp_path):
    stamps = iter(["2026-02-01T10:00:00.000Z", "2026-02-01T10:00:01.000Z"])
    store = TranscriptStore(tmp_path, stamp=lambda: next(stamps))
    conv = "e621e1f8-c36c-495a-93fc-0c247a3e6e5f"
    store.append_user(conv, opening_session="s1", text="oi/ü", surface="app")
    store.append_assistant(conv, opening_session="s1", text="olá", surface="app", engine="claude", model="m")
    lines = (tmp_path / f"{conv}.jsonl").read_text(encoding="utf-8").splitlines()
    assert lines[0] == '{"at":"2026-02-01T10:00:00.000Z","engine":"claude","kind":"session","reason":"new","session":"s1","v":1}'
    assert lines[1] == '{"at":"2026-02-01T10:00:00.000Z","kind":"user","surface":"app","text":"oi/ü","v":1}'
    assert lines[2] == ('{"at":"2026-02-01T10:00:01.000Z","engine":"claude","kind":"assistant","model":"m",'
                        '"surface":"app","text":"olá","v":1}')
    assert store.last_engine(conv) == "claude"
    assert [(m["role"], m["text"]) for m in store.messages(conv)] == [("user", "oi/ü"), ("assistant", "olá")]


def test_transcript_reads_a_mac_written_file_and_repairs_broken_tail(tmp_path):
    conv = "abc-123"
    (tmp_path / f"{conv}.jsonl").write_text(
        '{"at":"2026-01-01T00:00:00.000Z","engine":"claude","kind":"session","reason":"new","session":"s9","v":1}\n'
        '{"at":"2026-01-01T00:00:01.000Z","kind":"user","surface":"telegram","text":"oi","v":1}\n'
        '{"at":"2026-01-01T00:00:02.000Z","kind":"assis', encoding="utf-8")
    store = TranscriptStore(tmp_path)
    assert store.engine_session(conv, "claude") == "s9"
    store.append_user(conv, opening_session=None, text="de novo", surface="app")
    assert [m["text"] for m in store.messages(conv)] == ["oi", "de novo"]


def test_transcript_rejects_bad_ids(tmp_path):
    store = TranscriptStore(tmp_path)
    for bad in ["", "../x", "a/b", "x" * 65, "a b"]:
        assert store.messages(bad) == []


def test_transcript_context_for_rebuild(tmp_path):
    store = TranscriptStore(tmp_path)
    store.append_user("c1", opening_session=None, text="pergunta", surface="app")
    store.append_assistant("c1", opening_session=None, text="resposta", surface="app", engine="claude", model=None)
    context = store.context("c1")
    assert context.startswith("[Wisp conversation memory")
    assert "User: pergunta" in context and "Assistant: resposta" in context
    assert context.endswith("[end of Wisp conversation memory]")
    empty = TranscriptStore(tmp_path / "other")
    empty.append_user("c2", opening_session=None, text="so user", surface="app")
    assert empty.context("c2") is None


def test_data_dir_per_platform(tmp_path):
    home = str(tmp_path)
    assert data_dir({"WISP_DATA_DIR": str(tmp_path / "x")}, "darwin", home) == tmp_path / "x"
    assert data_dir({}, "darwin", home) == tmp_path / "Library" / "Application Support" / "Wisp"
    assert data_dir({"APPDATA": str(tmp_path / "Roaming")}, "win32", home) == tmp_path / "Roaming" / "Wisp"
    assert data_dir({}, "win32", home) == tmp_path / "AppData" / "Roaming" / "Wisp"
    assert data_dir({"XDG_DATA_HOME": str(tmp_path / "xdg")}, "linux", home) == tmp_path / "xdg" / "wisp"
    assert data_dir({}, "linux", home) == tmp_path / ".local" / "share" / "wisp"

