from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from wisp import compat
from wisp.meetings_win import recordings
from wisp.meetings_win.insights import compute_metrics
from wisp.meetings_win.segmenter import SegmenterConfig
from wisp.meetings_win.transcriber import Cancelled, MeetingTranscriber
from wisp.meetings_win.transcript import (PARAKEET_BACKUP_FILE, SILENT_NOTICE, SPARSE_NOTICE, is_sparse, merge_adjacent,
                                          noise_of, raw_note, read_transcript, segments_of, title_of, transcript_path,
                                          write_private, write_transcript)

Stage = Callable[[str, "float | None"], None]
NOTE_TIMEOUT_SECONDS = 1500


def _quiet(kind: str, fraction: float | None = None) -> None:
    return None


@dataclass
class NoteOutcome:
    generated: bool
    reason: str | None = None
    title: str | None = None


class NoteBusy(Exception):
    def __init__(self):
        super().__init__("A nota dessa reunião já está sendo gerada por outro processo.")


@dataclass
class _LiveCheck:
    document: dict | None
    sparse: bool
    noise: list = field(default_factory=list)


def run_wisp(argv: list[str], cancel: threading.Event | None = None, stdin: bytes | None = None,
             timeout: float = NOTE_TIMEOUT_SECONDS):
    env = {**os.environ, "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"}
    process = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, **compat.new_session_kwargs())
    waited = 0.0
    pending_input = stdin
    while True:
        try:
            out, err = process.communicate(input=pending_input, timeout=0.2)
            return process.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")
        except subprocess.TimeoutExpired:
            pending_input = None
            waited += 0.2
            if (cancel is not None and cancel.is_set()) or waited >= timeout:
                try:
                    compat.kill_process_tree(process.pid, compat.SIGTERM if not compat.IS_WINDOWS else compat.SIGKILL)
                except (ProcessLookupError, OSError):
                    pass
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        compat.kill_process_tree(process.pid, compat.SIGKILL)
                    except (ProcessLookupError, OSError):
                        pass
                if cancel is not None and cancel.is_set():
                    raise Cancelled()
                return 124, "", f"o processo passou de {int(timeout)}s"


def _json_line(text: str) -> dict:
    for line in reversed([l for l in text.splitlines() if l.strip()]):
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    return {}


WISP = [sys.executable, "-m", "wisp"]


class SubprocessNoteWriter:
    def __init__(self, wisp: list[str] | None = None):
        self._wisp = wisp or WISP

    def write_note(self, folder: Path, cancel: threading.Event | None = None) -> NoteOutcome:
        code, out, err = run_wisp([*self._wisp, "reuniao", "nota", str(folder)], cancel)
        if code == 3:
            raise NoteBusy()
        if code != 0:
            tail = (err.strip().splitlines() or [""])[-1]
            return NoteOutcome(False, _json_line(err).get("erro") or (f"o comando saiu com {code}: {tail}" if tail else f"o comando saiu com {code}"))
        report = _json_line(out)
        return NoteOutcome(bool(report.get("gerada")), report.get("motivo"), report.get("titulo"))


class SubprocessBrainWriter:
    def __init__(self, wisp: list[str] | None = None, brain: Callable[[], str | None] = lambda: None, recreate: bool = False):
        self._wisp = wisp or WISP
        self._brain = brain
        self._recreate = recreate

    def sync_note(self, folder: Path, cancel: threading.Event | None = None) -> Path:
        argv = [*self._wisp, "reuniao", "brain", str(folder)]
        root = self._brain()
        if root:
            argv += ["--brain", root]
        if self._recreate:
            argv.append("--recriar")
        code, out, err = run_wisp(argv, cancel)
        if code != 0:
            raise RuntimeError(_json_line(err).get("erro") or f"o comando saiu com {code}")
        saved = _json_line(out).get("nota")
        if not saved:
            raise RuntimeError("o comando não devolveu a nota do brain")
        return Path(saved)


class MeetingPipeline:
    def __init__(self, transcriber: MeetingTranscriber, notes, brain=None,
                 refiner: Callable[[dict], object] | None = None):
        self.transcriber = transcriber
        self.notes = notes
        self.brain = brain
        self.refiner = refiner

    def _refine(self, folder: Path, meta: dict, document: dict, stage: Stage, cancel) -> dict:
        refiner = self.refiner(meta) if self.refiner else None
        if refiner is None or not segments_of(document):
            return document
        stage("refining", 0.0)
        result = refiner.refine(folder, meta, document, lambda f: stage("refining", f), cancel)
        if result.document is not None:
            try:
                write_private(Path(folder) / PARAKEET_BACKUP_FILE,
                              json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
                write_transcript(folder, result.document)
                recordings.update_meta(folder, lambda m: m.pop("notice", None))
                return result.document
            except OSError:
                recordings.update_meta(
                    folder, lambda m: m.update(notice="Não consegui gravar a transcrição revisada; mantive a ao vivo."))
                try:
                    return read_transcript(folder)
                except (OSError, ValueError):
                    return document
        if result.notice:
            recordings.update_meta(folder, lambda m: m.update(notice=result.notice))
        return document

    def _live_check(self, folder: Path, meta: dict) -> _LiveCheck:
        if meta.get("status") == recordings.INTERRUPTED:
            return _LiveCheck(None, False)
        try:
            live = read_transcript(folder, live=True)
        except (OSError, ValueError):
            return _LiveCheck(None, False)
        if int(live.get("failed_segments") or 0) > 0:
            return _LiveCheck(None, False)
        segments = segments_of(live)
        if not segments:
            return _LiveCheck(None, True)
        live["duration_s"] = max(float(live.get("duration_s") or 0), float(meta.get("duration_s") or 0))
        merged = merge_adjacent(segments)
        live["segments"] = [s.to_json() for s in merged]
        if is_sparse(merged, live["duration_s"]):
            return _LiveCheck(None, True)
        return _LiveCheck(live, False, noise_of(live))

    def _transcribe_final(self, folder: Path, meta: dict, sensitive: bool, progress, cancel) -> tuple[dict, str | None]:
        started = _started(meta)

        def run(config):
            return self.transcriber.with_config(config).transcribe(
                folder, started, meta.get("sources") or "both", float(meta.get("duration_s") or 0), progress, cancel)

        document = run(SegmenterConfig.sensitive() if sensitive else None)
        raised = sensitive
        duration = max(float(document.get("duration_s") or 0), float(meta.get("duration_s") or 0))
        if not sensitive and is_sparse(segments_of(document), duration):
            retry = run(SegmenterConfig.sensitive())
            raised = True
            if len(retry["segments"]) >= len(document["segments"]):
                document = retry
        if not raised:
            return document, None
        return document, SILENT_NOTICE if not document["segments"] else SPARSE_NOTICE

    def improve_transcript(self, folder: Path, stage: Stage = _quiet, cancel: threading.Event | None = None) -> None:
        meta = recordings.read_meta(folder)
        stage("transcribing", 0.0)
        document, notice = self._transcribe_final(folder, meta, False, lambda f: stage("transcribing", f), cancel)
        if not document["segments"]:
            return
        write_transcript(folder, document)
        recordings.update_meta(folder, lambda m: m.update(notice=notice) if notice else m.pop("notice", None))
        refined = self._refine(folder, recordings.read_meta(folder), document, stage, cancel)
        stage("writing_note", None)
        self._write_note(folder, refined, recordings.read_meta(folder), cancel)

    def process(self, folder: Path, stage: Stage = _quiet, cancel: threading.Event | None = None) -> None:
        meta = recordings.read_meta(folder)
        if meta.get("status") == recordings.RECORDING:
            return
        if meta.get("status") == recordings.NOTED and (folder / recordings.NOTE_FILE).exists():
            return
        if meta.get("status") in (recordings.TRANSCRIBING, recordings.INTERRUPTED) or not transcript_path(folder).exists():
            try:
                stage("transcribing", 0.0)
                check = self._live_check(folder, meta)
                notice = None
                if check.document is not None:
                    document = check.document
                    if check.noise:
                        filled = self.transcriber.transcribe_ranges(folder, check.noise, lambda f: stage("transcribing", f), cancel)
                        document["segments"] = [s.to_json() for s in merge_adjacent(segments_of(document) + filled)]
                    document.pop("noise_ranges", None)
                else:
                    document, notice = self._transcribe_final(folder, meta, check.sparse,
                                                              lambda f: stage("transcribing", f), cancel)
                write_transcript(folder, document)
                try:
                    transcript_path(folder, live=True).unlink()
                except OSError:
                    pass
                empty = not document["segments"]

                def done(m):
                    m["status"] = recordings.TRANSCRIBED
                    if empty:
                        m["failure"] = "nenhuma fala detectada nessa gravação"
                    else:
                        m.pop("failure", None)
                    if notice:
                        m["notice"] = notice
                    else:
                        m.pop("notice", None)

                meta = recordings.update_meta(folder, done)
            except Cancelled:
                raise
            except Exception as problem:
                recordings.update_meta(folder, lambda m: m.update(status=recordings.FAILED,
                                                                  failure=f"não consegui transcrever: {problem}"))
                raise
        document = read_transcript(folder)
        if not segments_of(document):
            return
        if not (folder / PARAKEET_BACKUP_FILE).exists():
            document = self._refine(folder, recordings.read_meta(folder), document, stage, cancel)
            meta = recordings.read_meta(folder)
        if meta.get("summary_deferred") is True and not (folder / recordings.NOTE_FILE).exists():
            self._sync_brain(folder, cancel)
            return
        stage("writing_note", None)
        self._write_note(folder, document, meta, cancel)

    def regenerate_note(self, folder: Path, cancel: threading.Event | None = None) -> None:
        meta = recordings.read_meta(folder)
        self._write_note(folder, read_transcript(folder), meta, cancel)

    def _write_note(self, folder: Path, document: dict, meta: dict, cancel) -> None:
        metrics = compute_metrics(segments_of(document), float(document.get("duration_s") or 0)).metrics
        recordings.update_meta(folder, lambda m: m.update(metrics=metrics))
        try:
            outcome = self.notes.write_note(folder, cancel) if _takes_cancel(self.notes) else self.notes.write_note(folder)
        except (Cancelled, NoteBusy):
            raise
        except Exception as problem:
            outcome = NoteOutcome(False, str(problem))
        note = folder / recordings.NOTE_FILE
        if not note.exists():
            write_private(note, raw_note(outcome.title or "Reunião", document, outcome.reason or "o motor não devolveu a nota"))
            outcome = NoteOutcome(False, outcome.reason, outcome.title)
        title = outcome.title
        if title is None:
            try:
                title = title_of(note.read_text("utf-8"))
            except OSError:
                title = None

        def noted(m):
            m.update(status=recordings.NOTED, note_file=recordings.NOTE_FILE,
                     note_state="generated" if outcome.generated else "raw")
            if title:
                m["title"] = title
            if not outcome.generated and outcome.reason:
                m["failure"] = f"nota não gerada: {outcome.reason}"
            else:
                m.pop("failure", None)

        recordings.update_meta(folder, noted)
        self._sync_brain(folder, cancel)

    def _sync_brain(self, folder: Path, cancel) -> None:
        if self.brain is None:
            return
        try:
            saved = self.brain.sync_note(folder, cancel) if _takes_cancel(self.brain) else self.brain.sync_note(folder)
        except Cancelled:
            raise
        except Exception as problem:
            recordings.update_meta(folder, lambda m: m.update(brain_error=str(problem)))
            return

        def synced(m):
            m["brain_note"] = str(saved)
            m.pop("brain_error", None)

        recordings.update_meta(folder, synced)


def _takes_cancel(writer) -> bool:
    import inspect

    method = getattr(writer, "write_note", None) or getattr(writer, "sync_note")
    return "cancel" in inspect.signature(method).parameters


def _started(meta: dict):
    from wisp.meetings_win.transcript import parse_iso

    return parse_iso(str(meta["started_at"]))
