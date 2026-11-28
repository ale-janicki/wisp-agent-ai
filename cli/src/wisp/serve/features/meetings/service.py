from __future__ import annotations

import asyncio
import functools
import json
import logging
import secrets
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from wisp.meetings_win import copilot as cop
from wisp.meetings_win import janitor, recordings, settings, webhook
from wisp.meetings_win.insights import NudgeEngine, bookmark_lines, compute_metrics
from wisp.meetings_win.language import (LANGUAGE_LABELS, LIVE_ENGINE_NAME, LIVE_MODEL, POST_CALL_ENGINES, LanguagePicker,
                                        engine_of)
from wisp.meetings_win.live import LiveTranscriber, TranscriptStore
from wisp.meetings_win.models import MODELS, DownloadCancelled, ModelError, ModelStore
from wisp.meetings_win.pipeline import (MeetingPipeline, NoteBusy, SubprocessBrainWriter, SubprocessNoteWriter, run_wisp)
from wisp.meetings_win.recorder import MeetingRecorder
from wisp.meetings_win.refine import PostCallRefiner
from wisp.meetings_win.transcriber import Cancelled, MeetingTranscriber, audio_path
from wisp.meetings_win.transcript import clock, read_transcript, segments_of, transcript_path, write_private

FEATURE = "meetings"
log = logging.getLogger(__name__)
SOURCES = ("both", "mic", "system")
SOURCE_LABELS = {"both": "Microfone e áudio do computador", "mic": "Só microfone", "system": "Só áudio do computador"}
TICK_SECONDS = 1.0
METRICS_SECONDS = 2.0
LIVE_OFF_MESSAGE = ("O modelo de transcrição ainda não foi baixado: a gravação segue e a reunião é transcrita "
                    "assim que ele estiver instalado.")
ATTRIBUTION = "Modelos Whisper da OpenAI (licença MIT), convertidos para CTranslate2 pela Systran e pela Dropbox."


class Conflict(Exception):
    pass


class NotFound(Exception):
    pass


class Invalid(Exception):
    pass


class Forbidden(Exception):
    pass


CONFIRM_SECONDS = 30.0
RESERVED = {"CON", "PRN", "AUX", "NUL", *(f"COM{n}" for n in "123456789\u00b9\u00b2\u00b3"),
            *(f"LPT{n}" for n in "123456789\u00b9\u00b2\u00b3")}


def safe_id(meeting_id: str) -> bool:
    if not isinstance(meeting_id, str) or not meeting_id or meeting_id in (".", ".."):
        return False
    if any(c in meeting_id for c in '/\\:*?"<>|\0') or any(ord(c) < 32 for c in meeting_id):
        return False
    if meeting_id.startswith(".") or meeting_id.endswith((".", " ")):
        return False
    return meeting_id.split(".")[0].rstrip(" ").upper() not in RESERVED


@dataclass
class Env:
    data_dir: Path
    wisp_dir: Path
    home: Path
    state_dir: Path
    make_source: Callable[[str], object]
    store: ModelStore
    recognizer: Callable[[str, str, str], object]
    run: Callable[..., tuple]
    wisp: list
    secrets: object
    trash: Callable[[Path], None]
    reveal: Callable[[Path], None]
    send_webhook: Callable[..., None] = webhook.send
    clock: Callable[[], float] = time.perf_counter
    now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)
    free_bytes: Callable[[Path], int] | None = None
    note_writer: object | None = None
    brain_writer: object | None = None
    background: bool = True

    @property
    def settings_file(self) -> Path:
        return Path(self.data_dir) / "settings.json"


def default_env() -> Env:
    from wisp.meetings_win import winsys
    from wisp.meetings_win.asr import FasterWhisperRecognizer, Runtime, make_host
    from wisp.meetings_win.capture_win import PortAudioSource
    from wisp.paths import WispPaths
    from wisp.serve.store import data_dir, wisp_root

    wisp_dir = wisp_root()
    store = ModelStore.for_wisp(wisp_dir)
    shared: dict = {}

    def recognizer(model_id: str, profile: str, engine_name: str):
        if "host" not in shared:
            shared["runtime"] = Runtime.detect()
            shared["host"] = make_host(store, shared["runtime"])
        return FasterWhisperRecognizer(model_id, store, shared["host"], engine_name, shared["runtime"], profile)

    def run(argv, stdin=None, cancel=None):
        return run_wisp(argv, cancel, stdin)

    paths = WispPaths.current()
    state = Path(paths.state)
    return Env(data_dir=data_dir(), wisp_dir=wisp_dir, home=Path.home(), state_dir=state,
               make_source=lambda kind: PortAudioSource(kind), store=store, recognizer=recognizer, run=run,
               wisp=[sys.executable, "-m", "wisp"], secrets=winsys.CredentialStore(state / "meetings-secrets.json"),
               trash=winsys.trash, reveal=winsys.reveal)


ENV_FACTORY: Callable[[], Env] = default_env


def limit_text(minutes: int) -> str:
    return f"{minutes // 60} h" if minutes % 60 == 0 else f"{minutes} min"


@dataclass
class _Job:
    kind: str
    meeting: str
    cancel: threading.Event = field(default_factory=threading.Event)
    stage: str | None = None
    fraction: float | None = None


class MeetingsService:
    def __init__(self, host, env: Env):
        self._host = host
        self.env = env
        self._loop: asyncio.AbstractEventLoop | None = None
        self._lock = threading.RLock()
        self._phase = "idle"
        self._recorder: MeetingRecorder | None = None
        self._live: LiveTranscriber | None = None
        self._store: TranscriptStore | None = None
        self._picker: LanguagePicker | None = None
        self._lag = False
        self._saving: float | None = None
        self._message: dict | None = None
        self._ticker: threading.Thread | None = None
        self._tick_halt = threading.Event()
        self._closing = threading.Event()
        self._queue: list[_Job] = []
        self._jobs: dict[str, _Job] = {}
        self._wake = threading.Condition(self._lock)
        self._worker: threading.Thread | None = None
        self._downloads: dict[str, dict] = {}
        self._approval = webhook.WebhookApproval()
        self._confirmations: dict[str, tuple[str, float]] = {}
        self._cleanup_lock = threading.Lock()
        self._sources = self._saved_sources()
        self._prep: list[dict] = []
        self._reset_copilot()
        self._started = False

    def bind_loop(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop
        if not self._started:
            self._started = True
            threading.Thread(target=self._startup, name="wisp-meetings-startup", daemon=True).start() \
                if self.env.background else self._startup()

    def _emit(self, type_: str, **fields) -> None:
        loop = self._loop
        if loop is None or loop.is_closed():
            return
        try:
            loop.call_soon_threadsafe(functools.partial(self._host.publish_feature, FEATURE, type_, **fields))
        except RuntimeError:
            pass

    def _root(self) -> Path:
        top = settings.load(self.env.settings_file)
        return settings.recordings_root(top, self.env.wisp_dir, self.env.home)

    def _values(self) -> dict:
        return settings.read(self.env.settings_file)

    def _state_file(self) -> Path:
        return Path(self.env.data_dir) / "meetings-state.json"

    def _saved_sources(self) -> str:
        try:
            value = json.loads(self._state_file().read_text("utf-8")).get("sources")
        except (OSError, ValueError, AttributeError):
            value = None
        return value if value in SOURCES else "both"

    def _meeting_folder(self, meeting_id: str) -> Path:
        if not safe_id(meeting_id):
            log.warning("meeting %r not found: not a safe id", meeting_id)
            raise NotFound("reunião não encontrada")
        root = self._root()
        folder = root / meeting_id
        try:
            resolved, resolved_root = folder.resolve(), root.resolve()
            inside = resolved.parent == resolved_root
        except (OSError, ValueError) as problem:
            log.warning("meeting %r not found: cannot resolve %s: %r", meeting_id, folder, problem)
            raise NotFound("reunião não encontrada")
        if not inside:
            log.warning("meeting %r not found: %s resolves to %s, not directly under %s", meeting_id, folder, resolved,
                        resolved_root)
            raise NotFound("reunião não encontrada")
        if not recordings.has_meta(folder):
            log.warning("meeting %r not found: no %s in %s", meeting_id, recordings.META_FILE, folder)
            raise NotFound("reunião não encontrada")
        return folder

    def _recording_id(self) -> str | None:
        return self._recorder.folder.name if self._recorder and self._recorder.folder else None

    def is_recording(self) -> bool:
        return self._phase in ("starting", "recording")

    def close(self) -> None:
        self._closing.set()
        self._tick_halt.set()
        with self._wake:
            self._wake.notify_all()
        for job in list(self._jobs.values()):
            job.cancel.set()
        if self._phase == "recording":
            try:
                self.stop()
            except Exception:
                pass

    def _startup(self) -> None:
        try:
            root = self._root()
            recordings.recover(root, active={self._recording_id()} if self._recorder else ())
            for entry in reversed(recordings.pending(root)):
                self._enqueue("process", entry.id)
            self._emit("meetings")
            self.run_cleanup()
        except Exception as problem:
            self._emit("notice", message=f"não consegui retomar as reuniões pendentes: {problem}")

    def run_cleanup(self) -> dict:
        days = janitor.clamp(self._values()["cleanupDays"])
        if days <= 0:
            return {"removed": [], "failures": []}
        active = set(self._jobs) | ({self._recording_id()} if self._recorder else set())
        with self._cleanup_lock:
            report = janitor.run([self._root()], days=days, excluded=active, home=self.env.home, trash=self.env.trash,
                                 is_excluded=lambda meeting: meeting in self._jobs)
        if report["removed"]:
            self._emit("meetings")
        return report

    def state(self) -> dict:
        rec = self._recorder
        recording = self._phase == "recording" and rec is not None
        return {
            "phase": self._phase,
            "meeting": self._recording_id(),
            "elapsed": rec.elapsed() if recording else 0.0,
            "paused": bool(rec and rec.paused),
            "sources": self._sources,
            "source_labels": SOURCE_LABELS,
            "warnings": rec.warnings() if recording else [],
            "levels": rec.levels() if recording else {"mic": 0.0, "system": 0.0},
            "lag": self._lag,
            "saving": self._saving,
            "message": self._message,
            "live_model_ready": self.env.store.is_installed(LIVE_MODEL),
            "copilot": self._copilot_state(),
            "processing": {m: {"kind": j.kind, "stage": j.stage, "fraction": j.fraction} for m, j in self._jobs.items()},
            "webhook_offers": {m: self._offer_json(m, p) for m, p in self._approval.offers.items()},
        }

    def _publish_state(self) -> None:
        self._emit("state", state=self.state())

    def _notify(self, text: str, tone: str = "info") -> None:
        self._message = {"text": text, "tone": tone}
        self._publish_state()

    def dismiss_message(self) -> None:
        self._message = None
        self._publish_state()

    def set_sources(self, sources: str) -> dict:
        if sources not in SOURCES:
            raise Invalid("fonte inválida")
        if self._phase != "idle":
            raise Conflict("a fonte não muda durante a gravação")
        self._sources = sources
        try:
            self._state_file().parent.mkdir(parents=True, exist_ok=True)
            write_private(self._state_file(), json.dumps({"sources": sources}))
        except OSError:
            pass
        self._publish_state()
        return self.state()

    def start(self, sources: str | None = None) -> dict:
        with self._lock:
            if self._phase != "idle":
                raise Conflict("já tem uma gravação em andamento")
            self._phase = "starting"
            self._message = None
        self._publish_state()
        try:
            if sources and sources != self._sources:
                self._phase = "idle"
                self.set_sources(sources)
                self._phase = "starting"
            values = self._values()
            self._picker = LanguagePicker(values["language"])
            self._reset_copilot(keep_prep=True)
            live_ready = self.env.store.is_installed(LIVE_MODEL)
            self._store = TranscriptStore(self.env.now(), LIVE_ENGINE_NAME, values["language"])
            self._live = None
            if live_ready:
                self._live = LiveTranscriber(
                    self.env.recognizer(LIVE_MODEL, "live", LIVE_ENGINE_NAME), self._store, self._picker,
                    on_update=lambda snapshot: self._on_live_update(), on_failure=self._on_live_failure,
                    on_lag=self._on_live_lag)
            rec = MeetingRecorder(
                self._root(), self._sources, self.env.make_source("mic") if self._sources != "system" else None,
                self.env.make_source("system") if self._sources != "mic" else None, language=values["language"],
                limit_seconds=settings.limit_seconds(values), clock=self.env.clock, now=self.env.now, live=self._live,
                on_event=self._on_recorder_event, **({"free_bytes": self.env.free_bytes} if self.env.free_bytes else {}))
            folder = rec.start()
            self._store.attach(folder)
            self._recorder = rec
        except Exception as problem:
            if self._live is not None:
                self._live.stop_and_wait()
            self._live = None
            self._phase = "idle"
            text = str(problem) or problem.__class__.__name__
            self._notify(text, "error")
            raise
        self._phase = "recording"
        if not live_ready:
            self._notify(LIVE_OFF_MESSAGE)
        self._tick_halt.clear()
        self._ticker = threading.Thread(target=self._tick_loop, name="wisp-meetings-ticker", daemon=True)
        self._ticker.start()
        self._publish_state()
        self._emit("meetings")
        return self.state()

    def pause(self) -> dict:
        rec = self._require_recording()
        rec.pause()
        self._publish_state()
        return self.state()

    def resume(self) -> dict:
        rec = self._require_recording()
        rec.resume()
        self._publish_state()
        return self.state()

    def bookmark(self, label: str = "") -> dict:
        rec = self._require_recording()
        mark = rec.bookmark(label)
        self._emit("transcript", lines=self._lines())
        return mark

    def _require_recording(self) -> MeetingRecorder:
        if self._phase != "recording" or self._recorder is None:
            raise Conflict("não há gravação em andamento")
        return self._recorder

    def stop(self, notice: str | None = None) -> dict:
        with self._lock:
            if self._phase != "recording" or self._recorder is None:
                raise Conflict("não há gravação em andamento")
            self._phase = "finishing"
            self._saving = 0.0
        self._tick_halt.set()
        self._publish_state()
        rec, live, store = self._recorder, self._live, self._store
        folder = rec.folder
        try:
            result = rec.stop(progress=self._on_saving)
            checklist = list(self._checklist)
            if live is not None:
                if self._lag or live.has_failed:
                    live.stop_and_wait()
                    try:
                        transcript_path(folder, live=True).unlink()
                    except OSError:
                        pass
                else:
                    live.finish()
                self.env.recognizer(LIVE_MODEL, "live", LIVE_ENGINE_NAME).unload()
            values = self._values()
            deferred = not values["autoSummary"]

            def finish(meta: dict) -> None:
                if checklist:
                    meta["checklist"] = checklist
                if deferred:
                    meta["summary_deferred"] = True

            recordings.update_meta(folder, finish)
        except Exception as problem:
            self._phase = "idle"
            self._saving = None
            self._notify(f"não consegui salvar a gravação: {problem}", "error")
            raise
        self._recorder = None
        self._live = None
        self._lag = False
        self._saving = None
        self._phase = "idle"
        seconds = clock(result["duration_s"])
        self._notify(notice or (f"Gravação salva ({seconds})" if not result["failure"] else result["failure"]),
                     "error" if result["failure"] else "info")
        if not result["failure"]:
            self._enqueue("process", folder.name)
        self._emit("meetings")
        return self.state()

    def _on_saving(self, fraction: float) -> None:
        self._saving = fraction
        self._publish_state()

    def _on_live_update(self) -> None:
        self._emit("transcript", lines=self._lines())

    def _on_live_failure(self, reason: str) -> None:
        self._notify(f"A transcrição ao vivo falhou ({reason}); ela será refeita depois da gravação.", "error")

    def _on_live_lag(self, behind: bool) -> None:
        self._lag = behind
        self._publish_state()

    def _on_recorder_event(self, kind: str, detail=None) -> None:
        minutes = self._values()["limitMinutes"]
        if kind == "limit_warning":
            self._notify(f"A gravação para em {int((detail or 300) // 60)} min: limite de {limit_text(minutes)}.")
        elif kind in ("limit_reached", "fatal"):
            text = (f"A gravação parou: chegou ao limite de {limit_text(minutes)} de gravação."
                    if kind == "limit_reached" else str(detail))
            threading.Thread(target=self._stop_quietly, args=(text,), daemon=True).start()

    def _stop_quietly(self, text: str) -> None:
        try:
            self.stop(notice=text)
        except Exception:
            pass

    def _lines(self) -> list[dict]:
        rec = self._recorder
        segments = self._store.snapshot if self._store else []
        return bookmark_lines(segments, rec.bookmarks if rec else [], rec.pauses if rec else [])

    def _tick_loop(self) -> None:
        last_metrics = 0.0
        while not self._tick_halt.wait(TICK_SECONDS):
            try:
                self._publish_state()
                now = self.env.clock()
                if now - last_metrics >= METRICS_SECONDS:
                    last_metrics = now
                    self._copilot_tick()
            except Exception:
                pass

    def list_meetings(self) -> dict:
        entries = recordings.list_meetings(self._root())
        rows = [recordings.row_model(e, working=self._is_working(e.id)) for e in entries]
        recording = self._recording_id()
        for row in rows:
            if row["id"] == recording and self._phase in ("recording", "finishing"):
                row["badge"] = recordings.badge(recordings.RECORDING, False, False)
        return {"items": rows}

    def _is_working(self, meeting_id: str) -> bool:
        job = self._jobs.get(meeting_id)
        return bool(job and job.stage == "writing_note")

    def meeting(self, meeting_id: str) -> dict:
        folder = self._meeting_folder(meeting_id)
        entry = next((e for e in recordings.list_meetings(self._root()) if e.id == meeting_id), None)
        if entry is None:
            log.warning("meeting %r not found: %s exists but its %s could not be read", meeting_id, folder,
                        recordings.META_FILE)
            raise NotFound("reunião não encontrada")
        meta = entry.meta
        document = None
        for live in (False, True):
            try:
                document = read_transcript(folder, live=live)
                break
            except (OSError, ValueError):
                continue
        lines = bookmark_lines(segments_of(document) if document else [], meta.get("bookmarks") or [], meta.get("pauses") or [])
        note = None
        try:
            note = (folder / recordings.NOTE_FILE).read_text("utf-8")
        except OSError:
            pass
        brain_note = meta.get("brain_note")
        job = self._jobs.get(meeting_id)
        return {
            "row": recordings.row_model(entry, working=self._is_working(meeting_id)),
            "meta": {k: meta.get(k) for k in ("status", "failure", "notice", "brain_error", "started_at", "duration_s", "title",
                                              "metrics", "language", "note_state", "sources", "webhook_sent_at")},
            "note": note,
            "lines": lines,
            "has_audio": audio_path(folder) is not None,
            "brain": recordings.brain_button(brain_note, bool(brain_note and Path(brain_note).exists())),
            "job": {"kind": job.kind, "stage": job.stage, "fraction": job.fraction} if job else None,
            "webhook_offer": self._offer_json(meeting_id, self._approval.offers[meeting_id])
            if meeting_id in self._approval.offers else None,
        }

    def audio_file(self, meeting_id: str) -> Path:
        path = audio_path(self._meeting_folder(meeting_id))
        if path is None:
            raise NotFound("essa reunião não tem áudio")
        return path

    def open_folder(self, meeting_id: str) -> None:
        self.env.reveal(self._meeting_folder(meeting_id))

    def open_brain_note(self, meeting_id: str) -> None:
        note = recordings.read_meta(self._meeting_folder(meeting_id)).get("brain_note")
        if not note or not Path(note).exists():
            raise NotFound("a nota do brain não existe")
        self.env.reveal(Path(note))

    def _enqueue(self, kind: str, meeting_id: str) -> None:
        with self._wake:
            if meeting_id in self._jobs:
                return
            job = _Job(kind, meeting_id)
            self._jobs[meeting_id] = job
            self._queue.append(job)
            if self._worker is None or not self._worker.is_alive():
                self._worker = threading.Thread(target=self._work, name="wisp-meetings-worker", daemon=True)
                self._worker.start()
            self._wake.notify_all()
        self._emit("meetings")
        self._publish_state()

    def generate_note(self, meeting_id: str) -> dict:
        folder = self._meeting_folder(meeting_id)
        meta = recordings.read_meta(folder)
        if meeting_id in self._jobs:
            raise Conflict("essa reunião já está sendo processada")
        if meta.get("status") == recordings.RECORDING:
            raise Conflict("a reunião ainda está sendo gravada")
        if not transcript_path(folder).exists():
            raise Invalid("essa reunião ainda não tem transcrição")
        if (folder / recordings.NOTE_FILE).exists():
            self._enqueue("regenerate", meeting_id)
        else:
            def reopen(m: dict) -> None:
                m.pop("failure", None)
                m.pop("summary_deferred", None)

            recordings.update_meta(folder, reopen)
            self._enqueue("process", meeting_id)
        return self.meeting(meeting_id)

    def improve_transcript(self, meeting_id: str) -> dict:
        folder = self._meeting_folder(meeting_id)
        if meeting_id in self._jobs:
            raise Conflict("essa reunião já está sendo processada")
        if audio_path(folder) is None:
            raise Invalid("essa reunião não tem áudio para transcrever de novo")
        self._enqueue("improve", meeting_id)
        return self.meeting(meeting_id)

    def retry(self, meeting_id: str) -> dict:
        folder = self._meeting_folder(meeting_id)
        meta = recordings.read_meta(folder)
        if meeting_id in self._jobs:
            raise Conflict("essa reunião já está sendo processada")
        if meta.get("status") == recordings.FAILED and not transcript_path(folder).exists():
            def reopen(m: dict) -> None:
                m["status"] = recordings.TRANSCRIBING
                m.pop("failure", None)

            recordings.update_meta(folder, reopen)
            self._enqueue("process", meeting_id)
        else:
            return self.generate_note(meeting_id)
        return self.meeting(meeting_id)

    def cancel_job(self, meeting_id: str) -> None:
        job = self._jobs.get(meeting_id)
        if job is None:
            raise NotFound("nada em andamento nessa reunião")
        job.cancel.set()

    def save_to_brain(self, meeting_id: str, recreate: bool = False) -> dict:
        folder = self._meeting_folder(meeting_id)
        if meeting_id in self._jobs:
            raise Conflict("essa reunião já está sendo processada")
        writer = self.env.brain_writer or SubprocessBrainWriter(self.env.wisp, recreate=recreate)

        def sync() -> None:
            try:
                saved = writer.sync_note(folder)

                def ok(m: dict) -> None:
                    m["brain_note"] = str(saved)
                    m.pop("brain_error", None)

                recordings.update_meta(folder, ok)
            except Exception as problem:
                recordings.update_meta(folder, lambda m: m.update(brain_error=str(problem)))
            self._emit("meetings")
            self._emit("meeting", id=meeting_id)

        if self.env.background:
            threading.Thread(target=sync, daemon=True).start()
        else:
            sync()
        return self.meeting(meeting_id)

    def _pipeline(self) -> MeetingPipeline:
        values = self._values()
        engine = engine_of(values["postCallEngine"])
        final = self.env.recognizer(LIVE_MODEL, "live", LIVE_ENGINE_NAME)
        picker = LanguagePicker(values["language"])

        def wait_idle() -> None:
            if self.is_recording():
                final.unload()
                while self.is_recording() and not self._closing.is_set():
                    time.sleep(1.0)

        transcriber = MeetingTranscriber(final, picker, pause=wait_idle)

        def refiner(meta: dict):
            if engine["model"] is None:
                return None
            large = self.env.recognizer(engine["model"], "refine", engine["engine_name"])
            return PostCallRefiner(engine, str(meta.get("language") or values["language"]), large, self.env.store,
                                   is_recording=self.is_recording)

        notes = self.env.note_writer or SubprocessNoteWriter(self.env.wisp)
        brain = self.env.brain_writer or SubprocessBrainWriter(self.env.wisp)
        return MeetingPipeline(transcriber, notes, brain, refiner)

    def _work(self) -> None:
        while not self._closing.is_set():
            with self._wake:
                while not self._queue and not self._closing.is_set():
                    self._wake.wait(timeout=30)
                    if not self._queue:
                        self._worker = None
                        return
                if self._closing.is_set():
                    return
                job = self._queue.pop(0)
            while self.is_recording() and not self._closing.is_set():
                time.sleep(0.5)
            try:
                self._run_job(job)
            except Exception as problem:
                self._emit("notice", message=f"{job.meeting}: {problem}")
            finally:
                self._jobs.pop(job.meeting, None)
                self._emit("meetings")
                self._emit("meeting", id=job.meeting)
                self._publish_state()

    def _run_job(self, job: _Job) -> None:
        folder = self._root() / job.meeting
        pipeline = self._pipeline()

        def stage(kind: str, fraction: float | None = None) -> None:
            job.stage, job.fraction = kind, fraction
            self._emit("progress", id=job.meeting, stage=kind, fraction=fraction)
            if fraction is None or int((fraction or 0) * 100) % 5 == 0:
                self._publish_state()

        try:
            if job.kind == "regenerate":
                stage("writing_note")
                pipeline.regenerate_note(folder, job.cancel)
            elif job.kind == "improve":
                pipeline.improve_transcript(folder, stage, job.cancel)
            else:
                pipeline.process(folder, stage, job.cancel)
                self._offer_webhook(job.meeting, folder)
        except (Cancelled, NoteBusy) as problem:
            if isinstance(problem, NoteBusy):
                self._emit("notice", message=str(problem))
        except Exception as problem:
            self._emit("notice", message=f"{job.meeting}: {problem}")

    def models(self) -> dict:
        values = self._values()
        wanted = engine_of(values["postCallEngine"])["model"]
        items = []
        for model_id, spec in MODELS.items():
            download = self._downloads.get(model_id)
            items.append({
                "id": model_id, "label": spec.label, "license": spec.license, "size_bytes": spec.total_bytes,
                "role": "live" if model_id == LIVE_MODEL else "refine", "wanted": model_id in (LIVE_MODEL, wanted),
                "installed": self.env.store.is_installed(model_id),
                "downloading": bool(download and download.get("active")),
                "progress": download.get("progress") if download else None,
                "error": download.get("error") if download else None,
            })
        return {"items": items, "attribution": ATTRIBUTION}

    def download_model(self, model_id: str) -> dict:
        if model_id not in MODELS:
            raise NotFound("modelo desconhecido")
        with self._lock:
            current = self._downloads.get(model_id)
            if current and current.get("active"):
                raise Conflict("esse modelo já está sendo baixado")
            state = {"active": True, "progress": 0.0, "error": None, "cancel": threading.Event()}
            self._downloads[model_id] = state

        def progress(done: int, whole: int) -> None:
            state["progress"] = done / max(1, whole)
            self._emit("model", id=model_id, progress=state["progress"])

        def run() -> None:
            try:
                kwargs = {"free_bytes": self.env.free_bytes} if self.env.free_bytes else {}
                self.env.store.download(model_id, progress, state["cancel"], **kwargs)
                state["progress"] = 1.0
            except DownloadCancelled:
                state["error"] = None
            except ModelError as problem:
                state["error"] = str(problem)
            except Exception as problem:
                state["error"] = f"não consegui baixar o modelo: {problem}"
            finally:
                state["active"] = False
                self._emit("model", id=model_id, progress=state["progress"], done=True)
                self._emit("models")
                self._publish_state()

        if self.env.background:
            threading.Thread(target=run, name=f"wisp-model-{model_id}", daemon=True).start()
        else:
            run()
        return self.models()

    def cancel_download(self, model_id: str) -> dict:
        state = self._downloads.get(model_id)
        if not state or not state.get("active"):
            raise NotFound("nenhum download em andamento")
        state["cancel"].set()
        return self.models()

    def get_settings(self) -> dict:
        values = self._values()
        return {
            "values": values,
            "languages": [{"id": k, "label": v} for k, v in LANGUAGE_LABELS.items()],
            "engines": [{"id": e["id"], "label": e["label"]} for e in POST_CALL_ENGINES],
            "limit_choices": list(settings.LIMIT_CHOICES), "cleanup_choices": list(janitor.DAY_CHOICES),
            "recordings_path": str(self._root()), "webhook": self.webhook_config(),
            "brain_search": self._brain_search_available(),
        }

    def _brain_search_available(self) -> bool:
        now = self.env.clock()
        cached = getattr(self, "_brain_probe", None)
        if cached is None or now - cached[0] > 60:
            cached = (now, self._engine().brain_available())
            self._brain_probe = cached
        return cached[1]

    def put_settings(self, changes: dict) -> dict:
        try:
            settings.update(self.env.settings_file, changes)
        except ValueError as problem:
            raise Invalid(str(problem)) from None
        if "cleanupDays" in changes:
            threading.Thread(target=self.run_cleanup, daemon=True).start() if self.env.background else self.run_cleanup()
        return self.get_settings()

    def webhook_config(self) -> dict:
        url = self.env.secrets.get("url")
        masked = None
        if url:
            try:
                masked = webhook.Pending(webhook.validate(url), b"").masked_url
            except webhook.WebhookError:
                masked = None
        return {"url_set": bool(url), "masked_url": masked, "secret_set": bool(self.env.secrets.get("secret")),
                "enabled": self._values()["webhookEnabled"], "signs": self._values()["webhookSigns"]}

    def put_webhook(self, url: str | None = None, enabled: bool | None = None, signs: bool | None = None) -> dict:
        changes: dict = {}
        if url is not None:
            if url.strip():
                try:
                    webhook.validate(url)
                except webhook.WebhookError as problem:
                    raise Invalid(str(problem)) from None
                self.env.secrets.set("url", url.strip())
            else:
                self.env.secrets.delete("url")
        if enabled is not None:
            changes["webhookEnabled"] = enabled
        if signs is not None:
            changes["webhookSigns"] = signs
            if signs and not self.env.secrets.get("secret"):
                self.env.secrets.set("secret", secrets.token_hex(32))
        if changes:
            try:
                settings.update(self.env.settings_file, changes)
            except ValueError as problem:
                raise Invalid(str(problem)) from None
        return self.webhook_config()

    def webhook_secret(self) -> dict:
        return {"secret": self.env.secrets.get("secret")}

    def _offer_json(self, meeting_id: str, pending: webhook.Pending) -> dict:
        return {"id": meeting_id, "host": pending.host, "masked_url": pending.masked_url, "preview": pending.preview,
                "size": pending.size_text, "signed": pending.signed, "body": pending.body_text,
                "formatted": pending.formatted_body_text}

    def _offer_webhook(self, meeting_id: str, folder: Path) -> None:
        values = self._values()
        meta = recordings.read_meta(folder)
        url = self.env.secrets.get("url")
        if (not values["webhookEnabled"] or not url or meta.get("status") != recordings.NOTED
                or meta.get("note_state") != "generated" or meta.get("webhook_sent_at")):
            return
        try:
            note = (folder / recordings.NOTE_FILE).read_text("utf-8")
            body, preview = webhook.content(str(meta.get("title") or "Reunião"), str(meta.get("started_at") or ""),
                                            float(meta.get("duration_s") or 0), note, meta.get("metrics"))
            self._approval.offer(webhook.Pending(webhook.validate(url), body, preview, values["webhookSigns"]), meeting_id)
            self._offer_changed(meeting_id)
        except (OSError, webhook.WebhookError) as problem:
            self._emit("notice", message=f"não preparei o webhook: {problem}")
            return
        self._emit("webhook", id=meeting_id)

    def confirm_webhook(self, meeting_id: str) -> dict:
        self._meeting_folder(meeting_id)
        if meeting_id not in self._approval.offers:
            raise NotFound("nada para enviar")
        nonce = secrets.token_urlsafe(16)
        self._confirmations[meeting_id] = (nonce, self.env.clock())
        return {"confirm": nonce}

    def _offer_changed(self, meeting_id: str) -> None:
        self._confirmations.pop(meeting_id, None)

    def allow_webhook(self, meeting_id: str, confirm: str | None = None) -> dict:
        issued = self._confirmations.get(meeting_id)
        if issued is not None and self.env.clock() - issued[1] > CONFIRM_SECONDS:
            self._confirmations.pop(meeting_id, None)
            issued = None
        if (issued is None or not isinstance(confirm, str)
                or not secrets.compare_digest(issued[0].encode(), confirm.encode())):
            raise Forbidden("o envio precisa da confirmação do botão Permitir")
        self._confirmations.pop(meeting_id, None)
        pending = self._approval.approve(meeting_id)
        if pending is None:
            raise NotFound("nada para enviar")
        folder = self._meeting_folder(meeting_id)

        def send() -> None:
            secret = self.env.secrets.get("secret") if pending.signed else None
            try:
                self.env.send_webhook(pending, secret)
                recordings.update_meta(folder, lambda m: m.update(webhook_sent_at=webhook_time(self.env.now())))
                self._emit("webhook_result", id=meeting_id, ok=True)
            except webhook.WebhookError as problem:
                self._emit("webhook_result", id=meeting_id, ok=False, message=str(problem))
            except Exception as problem:
                self._emit("webhook_result", id=meeting_id, ok=False, message=f"o envio falhou: {problem}")
            self._publish_state()

        if self.env.background:
            threading.Thread(target=send, daemon=True).start()
        else:
            send()
        self._publish_state()
        return {"ok": True}

    def dismiss_webhook(self, meeting_id: str) -> dict:
        self._confirmations.pop(meeting_id, None)
        self._approval.dismiss(meeting_id)
        self._publish_state()
        return {"ok": True}

    def _engine(self) -> cop.EngineClient:
        return cop.EngineClient(self.env.run, self.env.wisp)

    def _reset_copilot(self, keep_prep: bool = False) -> None:
        for call in getattr(self, "_calls", {}).values():
            call.set()
        self._calls: dict[str, threading.Event] = {}
        self._assist_on = False
        self._lookup_on = False
        self._lookup_others = False
        self._nudges_on = False
        self._assist_gate = cop.AssistGate()
        self._lookup_gate = cop.LookupGate()
        self._nudge_engine = NudgeEngine()
        self._shown: list[cop.AssistItem] = []
        self._hits: list[cop.BrainHit] = []
        self._nudge: dict | None = None
        self._nudge_at = 0.0
        self._stats = None
        self._checklist = list(self._prep) if keep_prep else []
        if not keep_prep:
            self._prep = []
        self._context_event: dict | None = None
        self._description = ""

    def _copilot_state(self) -> dict:
        return {
            "assist": self._assist_on, "lookup": self._lookup_on, "lookup_others": self._lookup_others,
            "nudges": self._nudges_on, "items": [i.to_json() for i in self._shown], "hits": [h.to_json() for h in self._hits],
            "nudge": self._nudge, "metrics": self._stats.metrics if self._stats else None, "checklist": list(self._checklist),
            "prep": list(self._prep) if self._phase == "idle" else [],
        }

    def set_copilot(self, **toggles) -> dict:
        names = {"assist": "_assist_on", "lookup": "_lookup_on", "lookup_others": "_lookup_others", "nudges": "_nudges_on"}
        for key, value in toggles.items():
            if key not in names or not isinstance(value, bool):
                raise Invalid(f"opção inválida: {key}")
            setattr(self, names[key], value)
            if not value and key in ("assist", "lookup"):
                cancel = self._calls.get(key)
                if cancel is not None:
                    cancel.set()
                if key == "lookup":
                    self._hits = []
            if key == "nudges" and not value:
                self._nudge = None
        self._publish_state()
        return self._copilot_state()

    def dismiss_nudge(self) -> dict:
        self._nudge = None
        self._publish_state()
        return self._copilot_state()

    def prepare(self, title: str = "", description: str = "") -> dict:
        if not (title or description).strip():
            raise Invalid("escreva o assunto ou a descrição da reunião")
        try:
            report = self._engine().prep({"titulo": title, "descricao": description})
        except cop.EngineFailed as problem:
            raise Invalid(str(problem)) from None
        self._prep = [{"id": f"p{n}", "text": text, "done": False} for n, text in enumerate(cop.prep_items(report))]
        self._checklist = list(self._prep)
        self._description = description
        self._publish_state()
        return {"checklist": self._checklist}

    def toggle_check(self, item_id: str, done: bool) -> dict:
        for item in self._checklist:
            if item["id"] == item_id:
                item["done"] = done
                break
        else:
            raise NotFound("item não encontrado")
        self._publish_state()
        return {"checklist": self._checklist}

    def _copilot_tick(self) -> None:
        rec, store = self._recorder, self._store
        if rec is None or store is None or self._phase != "recording":
            return
        elapsed = rec.elapsed()
        segments = store.snapshot
        self._stats = compute_metrics(segments, elapsed)
        if self._nudges_on:
            if self._nudge and elapsed - self._nudge_at >= 30:
                self._nudge = None
            if self._nudge is None:
                made = self._nudge_engine.evaluate(self._stats, elapsed)
                if made:
                    self._nudge, self._nudge_at = {"kind": made.kind, "text": made.text}, elapsed
        finals = [s for s in segments if s.is_final]
        if self._assist_on and self._assist_gate.should_run(elapsed, len(finals)):
            self._assist_gate.started(elapsed, len(finals))
            threading.Thread(target=self._assist_call, args=(finals, elapsed), daemon=True).start()
        if self._lookup_on:
            names = cop.entities_in(finals, self._lookup_others)
            picked = self._lookup_gate.pick(names, elapsed)
            if picked:
                threading.Thread(target=self._lookup_call, args=(picked,), daemon=True).start()

    def _assist_call(self, finals, elapsed: float) -> None:
        cancel = self._calls.setdefault("assist", threading.Event())
        cancel.clear()
        try:
            text = cop.assist_window(finals, elapsed)
            context = cop.build_context(self._context_event, self._description, self._checklist, self._hits)
            fresh = self._engine().assist(text, context, [i.text for i in self._shown], cancel)
            if not cancel.is_set():
                self._shown = cop.merge_assist(fresh, self._shown)
        except Exception as problem:
            if not cancel.is_set():
                self._emit("notice", message=f"o Copiloto não respondeu: {problem}")
        finally:
            self._assist_gate.finished()
            self._publish_state()

    def _lookup_call(self, names: list[str]) -> None:
        cancel = self._calls.setdefault("lookup", threading.Event())
        cancel.clear()
        try:
            root = self._brain_root()
            if root is None:
                return
            for name in names:
                if cancel.is_set():
                    return
                for hit in self._engine().brain_search(name, root, 3):
                    if all(h.path != hit.path for h in self._hits):
                        self._hits.append(hit)
            self._hits = self._hits[:12]
        except Exception:
            pass
        finally:
            self._publish_state()

    def _brain_root(self) -> str | None:
        from wisp.layout import resolve_layout

        try:
            raw = json.loads(Path(self.env.home / ".config" / "wisp" / "wisp.json").read_text("utf-8"))
        except (OSError, ValueError):
            raw = {}
        layout = resolve_layout(raw if isinstance(raw, dict) else {}, self.env.home)
        return str(layout.brain) if layout.brain.is_dir() else None


def webhook_time(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
