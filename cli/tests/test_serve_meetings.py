import json
import time
from array import array
from datetime import datetime, timezone
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from wisp.meetings_win import recordings
from wisp.meetings_win.asr import RecognizeResult
from wisp.meetings_win.pipeline import NoteOutcome
from wisp.meetings_win.transcript import RecognizedSpan
from wisp.meetings_win.winsys import CredentialStore
from wisp.serve.app import create_app
from wisp.serve.features.meetings import service

TOKEN = "t0ken-for-tests"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
R = 48_000


class Source:
    def __init__(self, label, fail=None):
        self.label, self.fail, self.ring, self.stopped = label, fail, None, False

    def start(self, ring):
        if self.fail:
            raise RuntimeError(self.fail)
        self.ring = ring
        self.cursor = time.perf_counter()

    def stop(self):
        self.stopped = True

    def speak(self, seconds, amp=0.1):
        self.ring.push(array("f", [amp] * round(seconds * R)), 1, R, self.cursor)
        self.cursor += seconds


class Recognizer:
    engine_name = "fake-whisper"

    def __init__(self):
        self.calls = 0
        self.unloaded = 0

    def transcribe(self, samples, language):
        self.calls += 1
        return RecognizeResult([RecognizedSpan(f"frase {self.calls}", 0.1, 0.8, 0.9)], "pt", 0.9)

    def unload(self):
        self.unloaded += 1


class Store:
    def __init__(self, installed=("small",)):
        self.installed = set(installed)
        self.downloads = []
        self.fail = None

    def is_installed(self, model_id):
        return model_id in self.installed

    def folder(self, model_id):
        return Path("/models") / model_id

    def download(self, model_id, progress=None, cancel=None, **kwargs):
        if self.fail:
            raise self.fail
        self.downloads.append(model_id)
        progress(5, 10)
        progress(10, 10)
        self.installed.add(model_id)


class Notes:
    def __init__(self):
        self.calls = 0

    def write_note(self, folder, cancel=None):
        self.calls += 1
        (folder / "nota.md").write_text("# Plano\n\n## Resumo\n\nOk.\n\n## Ações\n- [ ] Enviar — responsável: Você — prazo: 10/05\n", encoding="utf-8")
        return NoteOutcome(True, None, "Plano")


class Brain:
    def sync_note(self, folder, cancel=None):
        return Path("/brain/meetings/plano.md")


class Env:
    def __init__(self, tmp_path, **overrides):
        self.sources = {"mic": Source("Microfone X"), "system": Source("Alto-falantes Y")}
        self.recognizer = Recognizer()
        self.store = Store()
        self.notes = Notes()
        self.sent = []
        self.trashed = []
        self.revealed = []
        self.runs = []
        self.run_result = (0, "{}", "")
        self.env = service.Env(
            data_dir=tmp_path / "data", wisp_dir=tmp_path / "wisp", home=tmp_path / "home", state_dir=tmp_path / "state",
            make_source=lambda kind: self.sources[kind], store=self.store, recognizer=lambda m, p, e: self.recognizer,
            run=self._run, wisp=["wisp"],
            secrets=CredentialStore(tmp_path / "secrets.json", lambda b: bytes(x ^ 9 for x in b), lambda b: bytes(x ^ 9 for x in b)),
            trash=self._trash, reveal=self.revealed.append, send_webhook=lambda p, secret: self.sent.append((p, secret)),
            free_bytes=lambda path: 10**12, note_writer=self.notes, brain_writer=Brain(), background=True)
        for key, value in overrides.items():
            setattr(self.env, key, value)

    def _trash(self, folder):
        import shutil

        self.trashed.append(folder)
        shutil.rmtree(folder)

    def _run(self, argv, stdin=None, cancel=None):
        self.runs.append((argv, stdin))
        return self.run_result


@pytest.fixture
def world(tmp_path, monkeypatch):
    holder = Env(tmp_path)
    monkeypatch.setattr(service, "ENV_FACTORY", lambda: holder.env)
    monkeypatch.setenv("WISP_DATA_DIR", str(tmp_path / "data"))
    with TestClient(create_app(TOKEN)) as client:
        client.headers.update(AUTH)
        holder.client = client
        host = client.app.app.app.state.host
        holder.events = host.hub.subscribe()
        yield holder
        svc = getattr(client.app.app.app.state, "meetings", None)
        if svc is not None:
            svc.close()


def wait_for(check, seconds=15.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("timed out waiting")


def record_a_meeting(world, speak=True):
    client = world.client
    started = client.post("/api/meetings/record/start", json={})
    assert started.status_code == 200, started.text
    if speak:
        for source in world.sources.values():
            source.speak(0.5, 0.0)
            source.speak(1.0)
            source.speak(1.0, 0.0)
        time.sleep(0.3)
    return client


def drain(queue):
    out = []
    while True:
        try:
            out.append(queue.get_nowait())
        except Exception:
            return out


def test_the_tab_needs_the_token():
    app = create_app(TOKEN)
    assert TestClient(app).get("/api/meetings/state").status_code == 401


def test_idle_state_and_an_empty_library(world):
    state = world.client.get("/api/meetings/state").json()
    assert state["phase"] == "idle" and state["sources"] == "both" and state["live_model_ready"] is True
    assert world.client.get("/api/meetings/meetings").json() == {"items": []}


def test_a_recording_goes_from_start_to_a_finished_meeting_with_note_and_brain(world):
    client = record_a_meeting(world)
    state = client.get("/api/meetings/state").json()
    assert state["phase"] == "recording" and state["meeting"] and state["warnings"] == []
    assert client.post("/api/meetings/record/start", json={}).status_code == 409
    assert client.post("/api/meetings/record/bookmark", json={"label": "preço"}).json()["label"] == "preço"
    assert client.post("/api/meetings/record/pause").json()["paused"] is True
    assert client.post("/api/meetings/record/resume").json()["paused"] is False
    meeting_id = state["meeting"]
    stopped = client.post("/api/meetings/record/stop").json()
    assert stopped["phase"] == "idle" and stopped["message"]["text"].startswith("Gravação salva (0:0")

    def finished():
        detail = client.get(f"/api/meetings/meetings/{meeting_id}").json()
        return detail if detail["meta"]["status"] == "noted" else None

    detail = wait_for(finished)
    assert detail["note"].startswith("# Plano") and detail["row"]["title"] == "Plano"
    assert detail["row"]["badge"] == {"label": "pronto", "tone": "ready"} and detail["has_audio"] is True
    assert detail["brain"] == {"label": "Salvar no brain", "opens_note": False}
    speakers = {line["speaker"] for line in detail["lines"]}
    assert {"Você", "Outros", "Marcador"} <= speakers
    assert detail["meta"]["metrics"]["you"]["words"] > 0 and detail["meta"]["duration_s"] > 0
    listing = client.get("/api/meetings/meetings").json()["items"]
    assert [row["id"] for row in listing] == [meeting_id]
    folder = Path(world.env.wisp_dir) / "reunioes" / meeting_id
    assert (folder / "audio.wav").exists() and (folder / "transcript.json").exists()
    assert not (folder / "transcript.live.json").exists()
    assert world.recognizer.unloaded >= 1 and world.notes.calls == 1


def test_events_carry_state_transcript_and_meetings_changes(world):
    record_a_meeting(world)
    world.client.post("/api/meetings/record/stop")
    wait_for(lambda: any(e["type"] == "meetings" for e in drain(world.events)) or None)
    events = [e for e in drain(world.events)]
    kinds = {e["type"] for e in events}
    assert all(e["feature"] == "meetings" for e in events)
    wait_for(lambda: world.client.get("/api/meetings/meetings").json()["items"][0]["badge"]["label"] == "pronto")
    assert kinds <= {"state", "transcript", "meetings", "meeting", "progress", "notice", "model", "models", "webhook",
                     "webhook_result"}


def test_stopping_with_nothing_recording_and_pausing_are_conflicts(world):
    for path in ("record/stop", "record/pause", "record/resume", "record/bookmark"):
        assert world.client.post(f"/api/meetings/{path}", json={}).status_code == 409


def test_a_source_that_cannot_open_leaves_no_recording_and_says_why(world):
    world.sources["system"].fail = "o Windows não deixou usar o áudio"
    response = world.client.post("/api/meetings/record/start", json={})
    assert response.status_code == 500 and "não deixou" in response.json()["error"]
    state = world.client.get("/api/meetings/state").json()
    assert state["phase"] == "idle" and state["message"]["tone"] == "error"
    assert world.sources["mic"].stopped
    assert world.client.get("/api/meetings/meetings").json()["items"] == []


def test_the_source_choice_is_remembered_and_decides_what_is_started(world):
    assert world.client.put("/api/meetings/record/sources", json={"sources": "mic"}).json()["sources"] == "mic"
    assert world.client.put("/api/meetings/record/sources", json={"sources": "nope"}).status_code == 400
    assert world.client.get("/api/meetings/state").json()["sources"] == "mic"
    world.client.post("/api/meetings/record/start", json={})
    assert world.sources["mic"].ring is not None and world.sources["system"].ring is None
    assert world.client.put("/api/meetings/record/sources", json={"sources": "both"}).status_code == 409
    world.client.post("/api/meetings/record/stop")


def test_without_the_live_model_the_recording_still_runs_and_says_it_will_transcribe_later(world):
    world.store.installed.clear()
    world.client.post("/api/meetings/record/start", json={})
    state = world.client.get("/api/meetings/state").json()
    assert state["phase"] == "recording" and state["live_model_ready"] is False
    assert "transcrita assim que ele estiver instalado" in state["message"]["text"]
    world.client.post("/api/meetings/record/stop")


def test_models_list_download_progress_and_cancel(world):
    items = {m["id"]: m for m in world.client.get("/api/meetings/models").json()["items"]}
    assert items["small"]["installed"] and items["small"]["role"] == "live" and items["small"]["wanted"]
    assert not items["large-v3"]["installed"] and items["large-v3"]["wanted"] and not items["large-v3-turbo"]["wanted"]
    assert "MIT" in world.client.get("/api/meetings/models").json()["attribution"]
    world.client.post("/api/meetings/models/large-v3/download")
    wait_for(lambda: world.store.downloads == ["large-v3"])
    wait_for(lambda: {m["id"]: m for m in world.client.get("/api/meetings/models").json()["items"]}["large-v3"]["installed"])
    assert world.client.post("/api/meetings/models/nope/download").status_code == 404
    assert world.client.post("/api/meetings/models/small/cancel").status_code == 404


def test_a_failed_download_is_reported_on_the_model(world):
    world.store.fail = RuntimeError("sem rede")
    world.client.post("/api/meetings/models/large-v3/download")
    item = wait_for(lambda: next(m for m in world.client.get("/api/meetings/models").json()["items"]
                                 if m["id"] == "large-v3" and m["error"]))
    assert "sem rede" in item["error"] and not item["downloading"]


def test_settings_are_read_validated_and_written_to_the_mac_shaped_file(world):
    got = world.client.get("/api/meetings/settings").json()
    assert got["values"]["language"] == "pt" and got["values"]["limitMinutes"] == 120 and 120 in got["limit_choices"]
    assert [e["id"] for e in got["engines"]] == ["whisperLargeV3", "whisperTurbo", "off"]
    put = world.client.put("/api/meetings/settings", json={"language": "en", "cleanupDays": 14, "autoSummary": False})
    assert put.json()["values"]["language"] == "en"
    raw = json.loads((world.env.data_dir / "settings.json").read_text("utf-8"))
    assert raw["meetings"]["cleanupDays"] == 14 and raw["meetings"]["autoSummary"] is False
    assert world.client.put("/api/meetings/settings", json={"language": "xx"}).status_code == 400
    assert world.client.put("/api/meetings/settings", json={"bogus": 1}).status_code == 400


def make_noted_meeting(world, name="2026-04-01_10-00-00", brain=None):
    root = world.env.wisp_dir / "reunioes"
    folder = root / name
    folder.mkdir(parents=True)
    meta = recordings.new_meta(datetime(2026, 4, 1, 10, 0, tzinfo=timezone.utc))
    meta.update(status="noted", note_state="generated", title="Antiga", duration_s=60.0, brain_note=str(brain) if brain else None)
    recordings.write_meta(folder, meta)
    (folder / "nota.md").write_text("# Antiga\n", encoding="utf-8")
    return folder


def test_a_noted_meeting_already_in_the_brain_is_cleaned_up_when_the_setting_turns_on(world, tmp_path):
    brain = tmp_path / "brain" / "n.md"
    brain.parent.mkdir()
    brain.write_text("# Antiga\n", encoding="utf-8")
    folder = make_noted_meeting(world, brain=brain)
    world.client.put("/api/meetings/settings", json={"cleanupDays": 7})
    wait_for(lambda: world.trashed == [folder])


def test_the_library_actions_open_the_folder_and_guard_unknown_ids(world):
    folder = make_noted_meeting(world)
    assert world.client.post(f"/api/meetings/meetings/{folder.name}/open-folder").status_code == 200
    assert world.revealed == [folder]
    assert world.client.get("/api/meetings/meetings/nao-existe").status_code == 404
    assert world.client.get("/api/meetings/meetings/..%2Fx").status_code in (404, 400)
    assert world.client.post("/api/meetings/meetings/nao-existe/note").status_code == 404


def test_audio_is_served_with_the_token_only(world):
    folder = make_noted_meeting(world)
    assert world.client.get(f"/api/meetings/meetings/{folder.name}/audio").status_code == 404
    (folder / "audio.wav").write_bytes(b"RIFFxxxxWAVE")
    got = world.client.get(f"/api/meetings/meetings/{folder.name}/audio")
    assert got.status_code == 200 and got.content == b"RIFFxxxxWAVE" and got.headers["content-type"] == "audio/wav"
    assert TestClient(world.client.app).get(f"/api/meetings/meetings/{folder.name}/audio").status_code == 401


def test_generate_note_again_cancel_and_busy_guards(world):
    folder = make_noted_meeting(world)
    (folder / "transcript.json").write_text(json.dumps({"segments": [
        {"start": 0, "end": 2, "speaker": "eu", "text": "olá a todos"}], "duration_s": 5, "started_at": "2026-04-01T10:00:00Z"}), encoding="utf-8")
    first = world.client.post(f"/api/meetings/meetings/{folder.name}/note")
    assert first.status_code == 200
    wait_for(lambda: world.notes.calls == 1)
    assert world.client.post("/api/meetings/meetings/nao/cancel").status_code == 404
    bare = world.env.wisp_dir / "reunioes" / "2026-04-02_10-00-00"
    bare.mkdir()
    meta = recordings.new_meta(datetime(2026, 4, 2, 10, 0, tzinfo=timezone.utc))
    recordings.write_meta(bare, meta)
    assert world.client.post(f"/api/meetings/meetings/{bare.name}/note").status_code == 409


def test_retry_reopens_a_failed_meeting_and_the_pipeline_finishes_it(world):
    folder = make_noted_meeting(world, "2026-04-03_10-00-00")
    recordings.update_meta(folder, lambda m: m.update(status="failed", failure="não consegui transcrever: sem modelo"))
    (folder / "nota.md").unlink()
    from wisp.meetings_win.wavfile import StereoWavWriter

    writer = StereoWavWriter(folder / "audio.wav")
    writer.write(array("f", ([0.0, 0.0] * R) + ([0.1, 0.0] * R) + ([0.0, 0.0] * R * 2)))
    writer.close()
    assert world.client.post(f"/api/meetings/meetings/{folder.name}/retry").status_code == 200
    detail = wait_for(lambda: (d := world.client.get(f"/api/meetings/meetings/{folder.name}").json())
                      and d["meta"]["status"] == "noted" and d)
    assert detail["note"].startswith("# Plano") and world.recognizer.calls >= 1


def test_launch_recovery_finishes_a_recording_that_was_cut_short(tmp_path, monkeypatch):
    holder = Env(tmp_path)
    root = holder.env.wisp_dir / "reunioes"
    folder = root / "2026-04-04_09-00-00"
    folder.mkdir(parents=True)
    recordings.write_meta(folder, recordings.new_meta(datetime(2026, 4, 4, 9, 0, tzinfo=timezone.utc)))
    from wisp.meetings_win.wavfile import StereoWavWriter

    writer = StereoWavWriter(folder / "audio.wav")
    writer.write(array("f", ([0.0, 0.0] * R) + ([0.1, 0.0] * R) + ([0.0, 0.0] * R * 2)))
    writer._file.flush()
    monkeypatch.setattr(service, "ENV_FACTORY", lambda: holder.env)
    monkeypatch.setenv("WISP_DATA_DIR", str(tmp_path / "data"))
    with TestClient(create_app(TOKEN)) as client:
        client.headers.update(AUTH)
        assert client.get("/api/meetings/state").status_code == 200
        detail = wait_for(lambda: (d := client.get(f"/api/meetings/meetings/{folder.name}").json())
                          and d["meta"]["status"] == "noted" and d)
        assert detail["meta"]["duration_s"] == pytest.approx(4.0)
        client.app.app.app.state.meetings.close()


def webhook_setup(world, enabled=True, signs=True):
    assert world.client.put("/api/meetings/webhook", json={"url": "https://hooks.example.org/in", "enabled": enabled,
                                                          "signs": signs}).status_code == 200


def test_webhook_config_validates_masks_and_keeps_the_url_out_of_settings(world):
    assert world.client.put("/api/meetings/webhook", json={"url": "http://127.0.0.1/x"}).status_code == 400
    webhook_setup(world)
    config = world.client.get("/api/meetings/webhook").json()
    assert config == {"url_set": True, "masked_url": "https://hooks.example.org/•••", "secret_set": True, "enabled": True,
                      "signs": True}
    assert "hooks.example" not in (world.env.data_dir / "settings.json").read_text("utf-8")
    secret = world.client.get("/api/meetings/webhook/secret").json()["secret"]
    assert len(secret) == 64
    world.client.put("/api/meetings/webhook", json={"url": ""})
    assert world.client.get("/api/meetings/webhook").json()["url_set"] is False


def test_a_finished_meeting_offers_the_webhook_and_nothing_leaves_before_allow(world):
    webhook_setup(world)
    record_a_meeting(world)
    meeting = world.client.get("/api/meetings/state").json()["meeting"]
    world.client.post("/api/meetings/record/stop")
    offer = wait_for(lambda: world.client.get("/api/meetings/state").json()["webhook_offers"].get(meeting))
    assert offer["host"] == "hooks.example.org" and offer["masked_url"] == "https://hooks.example.org/•••" and offer["signed"]
    assert json.loads(offer["body"])["event"] == "meeting.finished" and world.sent == []
    assert world.client.post(f"/api/meetings/meetings/{meeting}/webhook/allow").status_code == 403
    assert world.sent == []
    nonce = world.client.post(f"/api/meetings/meetings/{meeting}/webhook/confirm").json()["confirm"]
    assert world.client.post(f"/api/meetings/meetings/{meeting}/webhook/allow", json={"confirm": "wrong"}).status_code == 403
    assert world.client.post(f"/api/meetings/meetings/{meeting}/webhook/allow", json={"confirm": nonce}).status_code == 200
    wait_for(lambda: world.sent)
    pending, secret = world.sent[0]
    assert pending.host == "hooks.example.org" and len(secret) == 64
    wait_for(lambda: world.client.get(f"/api/meetings/meetings/{meeting}").json()["meta"]["webhook_sent_at"])
    nonce = world.client.post(f"/api/meetings/meetings/{meeting}/webhook/confirm").json().get("confirm")
    assert world.client.post(f"/api/meetings/meetings/{meeting}/webhook/allow", json={"confirm": nonce}).status_code in (403, 404)
    assert len(world.sent) == 1


def test_dismissing_the_webhook_offer_sends_nothing(world):
    webhook_setup(world, signs=False)
    record_a_meeting(world)
    meeting = world.client.get("/api/meetings/state").json()["meeting"]
    world.client.post("/api/meetings/record/stop")
    wait_for(lambda: world.client.get("/api/meetings/state").json()["webhook_offers"].get(meeting))
    world.client.post(f"/api/meetings/meetings/{meeting}/webhook/dismiss")
    assert world.client.get("/api/meetings/state").json()["webhook_offers"] == {} and world.sent == []


def test_copilot_toggles_start_off_and_prep_builds_a_checklist_from_the_engine(world):
    state = world.client.get("/api/meetings/state").json()["copilot"]
    assert (state["assist"], state["lookup"], state["nudges"]) == (False, False, False)
    got = world.client.put("/api/meetings/copilot", json={"assist": True, "nudges": True}).json()
    assert got["assist"] and got["nudges"]
    assert world.client.put("/api/meetings/copilot", json={"assist": "yes"}).status_code == 400
    world.run_result = (0, json.dumps({"checklist": ["Revisar proposta"], "perguntas": ["Qual o prazo?"]}), "")
    prep = world.client.post("/api/meetings/copilot/prep", json={"title": "Kickoff", "description": "alinhar escopo"}).json()
    assert [c["text"] for c in prep["checklist"]] == ["Revisar proposta", "Perguntar: Qual o prazo?"]
    argv, stdin = world.runs[-1]
    assert argv == ["wisp", "reuniao", "prep"] and json.loads(stdin)["titulo"] == "Kickoff"
    checked = world.client.put(f"/api/meetings/copilot/checklist/{prep['checklist'][0]['id']}", json={"done": True}).json()
    assert checked["checklist"][0]["done"] is True
    assert world.client.put("/api/meetings/copilot/checklist/zzz", json={"done": True}).status_code == 404
    assert world.client.post("/api/meetings/copilot/prep", json={}).status_code == 400
    world.run_result = (1, "", json.dumps({"erro": "a IA local não está pronta: sem modelo"}))
    failed = world.client.post("/api/meetings/copilot/prep", json={"title": "x"})
    assert failed.status_code == 400 and "a IA local não está pronta" in failed.json()["error"]


def test_the_prep_checklist_goes_into_the_recording_and_is_saved_with_it(world):
    world.run_result = (0, json.dumps({"checklist": ["Revisar proposta"], "perguntas": []}), "")
    world.client.post("/api/meetings/copilot/prep", json={"title": "Kickoff"})
    record_a_meeting(world)
    state = world.client.get("/api/meetings/state").json()
    assert [c["text"] for c in state["copilot"]["checklist"]] == ["Revisar proposta"]
    world.client.post("/api/meetings/record/stop")
    folder = next((world.env.wisp_dir / "reunioes").iterdir())
    assert recordings.read_meta(folder)["checklist"][0]["text"] == "Revisar proposta"


def test_live_metrics_and_nudges_follow_the_transcript_while_recording(world):
    record_a_meeting(world)
    svc = world.client.app.app.app.state.meetings
    world.client.put("/api/meetings/copilot", json={"nudges": True})
    wait_for(lambda: svc._store.finals)
    svc._copilot_tick()
    stats = world.client.get("/api/meetings/state").json()["copilot"]["metrics"]
    assert stats["you"]["words"] >= 2 and stats["duration_s"] > 0
    world.client.post("/api/meetings/record/stop")


def test_a_confirmation_is_one_use_expires_and_needs_an_offer(world):
    webhook_setup(world, signs=False)
    record_a_meeting(world)
    meeting = world.client.get("/api/meetings/state").json()["meeting"]
    world.client.post("/api/meetings/record/stop")
    wait_for(lambda: world.client.get("/api/meetings/state").json()["webhook_offers"].get(meeting))
    svc = world.client.app.app.app.state.meetings
    url = f"/api/meetings/meetings/{meeting}/webhook"
    stale = world.client.post(f"{url}/confirm").json()["confirm"]
    svc._confirmations[meeting] = (stale, time.perf_counter() - 3600)
    assert world.client.post(f"{url}/allow", json={"confirm": stale}).status_code == 403
    assert world.client.post("/api/meetings/meetings/nao-existe/webhook/confirm").status_code == 404
    assert world.sent == []
    world.client.post(f"{url}/dismiss")
    assert world.client.post(f"{url}/confirm").status_code == 404


@pytest.mark.parametrize("bad", ["C:foo", "c:", "a:b", "CON", "con", "NUL.txt", "com1", "LPT9.log", "AUX", "PRN", "x.", "x ",
                                 "..", ".", ".hidden", "a/b", "a\\b", "", "COM\u00b9", "nested:stream"])
def test_meeting_ids_that_could_leave_the_recordings_folder_are_refused(world, bad):
    svc = world.client.app.app.app.state.meetings if hasattr(world.client.app.app.app.state, "meetings") else None
    if svc is None:
        world.client.get("/api/meetings/state")
        svc = world.client.app.app.app.state.meetings
    with pytest.raises(service.NotFound):
        svc._meeting_folder(bad)


def test_a_folder_that_is_a_link_to_somewhere_else_is_refused(world, tmp_path):
    world.client.get("/api/meetings/state")
    svc = world.client.app.app.app.state.meetings
    outside = tmp_path / "outside"
    outside.mkdir()
    recordings.write_meta(outside, recordings.new_meta(datetime(2026, 4, 1, 10, 0, tzinfo=timezone.utc)))
    root = world.env.wisp_dir / "reunioes"
    root.mkdir(parents=True, exist_ok=True)
    try:
        (root / "linked").symlink_to(outside, target_is_directory=True)
    except OSError:
        pytest.skip("no symlinks here")
    with pytest.raises(service.NotFound):
        svc._meeting_folder("linked")
    assert world.client.get("/api/meetings/meetings/linked").status_code == 404
    make_noted_meeting(world, "2026-04-05_10-00-00")
    assert svc._meeting_folder("2026-04-05_10-00-00").name == "2026-04-05_10-00-00"


def test_a_non_ascii_confirmation_is_refused_not_a_crash(world):
    webhook_setup(world, signs=False)
    record_a_meeting(world)
    meeting = world.client.get("/api/meetings/state").json()["meeting"]
    world.client.post("/api/meetings/record/stop")
    wait_for(lambda: world.client.get("/api/meetings/state").json()["webhook_offers"].get(meeting))
    url = f"/api/meetings/meetings/{meeting}/webhook"
    world.client.post(f"{url}/confirm")
    assert world.client.post(f"{url}/allow", json={"confirm": "çãé"}).status_code == 403
    assert world.sent == []


def test_a_new_offer_voids_a_confirmation_issued_for_the_old_one(world):
    webhook_setup(world, signs=False)
    record_a_meeting(world)
    meeting = world.client.get("/api/meetings/state").json()["meeting"]
    world.client.post("/api/meetings/record/stop")
    wait_for(lambda: world.client.get("/api/meetings/state").json()["webhook_offers"].get(meeting))
    svc = world.client.app.app.app.state.meetings
    url = f"/api/meetings/meetings/{meeting}/webhook"
    old = world.client.post(f"{url}/confirm").json()["confirm"]
    svc._approval.offer(svc._approval.offers[meeting], meeting)
    svc._offer_changed(meeting)
    assert world.client.post(f"{url}/allow", json={"confirm": old}).status_code == 403
    assert world.sent == []
