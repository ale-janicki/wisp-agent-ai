from __future__ import annotations

import threading
import time
from array import array
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from wisp.meetings_win.asr import RecognitionInterrupted
from wisp.meetings_win.audio import SPEECH_RATE, Decimator48To16, LinearResampler, from_numpy, mean_squares
from wisp.meetings_win.bleed import BleedConfig, BleedDetector
from wisp.meetings_win.hallucination import ChannelEnvelope, filter_spans
from wisp.meetings_win.language import refine_language
from wisp.meetings_win.transcriber import Cancelled, audio_path, uses
from wisp.meetings_win.transcript import CHANNELS, RecognizedSpan, TranscriptMerger, merge_adjacent
from wisp.meetings_win.wavfile import SAMPLE_RATE, info, read_blocks, read_frames

WINDOW_SECONDS = 300
OVERLAP_SECONDS = 1
TAPS = 95
CUTOFF_HZ = 7_200
KAISER_BETA = 8.0
POLL_SECONDS = 2.0


class HighQualityDecimator:
    def __init__(self):
        try:
            import numpy
        except ImportError:
            self._np = None
            self._box = Decimator48To16()
            return
        self._np = numpy
        n = numpy.arange(TAPS) - (TAPS - 1) / 2
        taps = numpy.sinc(2 * CUTOFF_HZ / SAMPLE_RATE * n) * numpy.kaiser(TAPS, KAISER_BETA)
        self._taps = taps / taps.sum()
        self._tail = numpy.zeros(TAPS - 1, dtype=numpy.float64)
        self._phase = 0

    def process(self, samples) -> array:
        if self._np is None:
            return self._box.process(samples)
        np = self._np
        data = np.concatenate([self._tail, np.asarray(samples, dtype=np.float64)])
        self._tail = data[-(TAPS - 1):] if len(data) >= TAPS - 1 else data
        filtered = np.convolve(data, self._taps, mode="valid")
        out = filtered[self._phase::3]
        self._phase = (self._phase - len(filtered)) % 3
        return from_numpy(out)


def _reducer(rate: int):
    return HighQualityDecimator() if rate == SAMPLE_RATE else LinearResampler(rate, SPEECH_RATE)


@dataclass
class RefineResult:
    document: dict | None = None
    notice: str | None = None
    dropped: int = 0


def window_16k(audio: Path, channel: int, start: int, stop: int) -> array:
    lanes = read_frames(audio, start * 3, (stop - start) * 3)
    if not lanes or channel >= len(lanes):
        return array("f", bytes(4 * max(0, stop - start)))
    return Decimator48To16().process(lanes[channel])


class PostCallRefiner:
    def __init__(self, engine: dict, language: str, recognizer, store, is_recording: Callable[[], bool] = lambda: False,
                 sleep: Callable[[float], None] = time.sleep, bleed: BleedConfig | None = None):
        self.engine = engine
        self.language = language
        self.recognizer = recognizer
        self.store = store
        self.is_recording = is_recording
        self.sleep = sleep
        self.bleed = bleed or BleedConfig()

    def _wait_for_idle(self, cancel: threading.Event | None) -> None:
        if not self.is_recording():
            return
        self.recognizer.unload()
        while True:
            if cancel is not None and cancel.is_set():
                raise Cancelled()
            self.sleep(POLL_SECONDS)
            if not self.is_recording():
                return

    def refine(self, folder: Path, meta: dict, original: dict, progress: Callable[[float], None],
               cancel: threading.Event | None = None) -> RefineResult:
        model = self.engine.get("model")
        if model is None:
            return RefineResult()
        if not self.store.is_installed(model):
            return RefineResult(notice=f"O modelo {self.engine['label']} não foi baixado; mantive a transcrição ao vivo.")
        audio = audio_path(folder)
        if audio is None:
            return RefineResult(notice="Não achei o áudio para revisar a transcrição; mantive a transcrição ao vivo.")
        channels = [c for c in CHANNELS if uses(c, meta.get("sources") or "both")]
        language = refine_language(self.language, original.get("language"))
        detected: list[str | None] = [None]
        try:
            merger = TranscriptMerger()
            dropped = 0
            for index, channel in enumerate(channels):
                spans, lost = self._channel(audio, channel, language, detected,
                                            lambda f, i=index: progress((i + f) / len(channels)), cancel)
                dropped += lost
                merger.commit(spans, channel)
            segments = merge_adjacent(merger.finals)
            if not segments:
                return RefineResult(notice="O Whisper não achou fala nessa gravação; mantive a transcrição ao vivo.",
                                    dropped=dropped)
            document = dict(original)
            document.update({
                "segments": [s.to_json() for s in segments], "engine": self.engine["engine_name"],
                "language": language or detected[0] or "auto",
                "duration_s": max(float(original.get("duration_s") or 0), max(s.end for s in segments)),
            })
            document.pop("failed_segments", None)
            document.pop("noise_ranges", None)
            progress(1.0)
            return RefineResult(document, None, dropped)
        except Cancelled:
            return RefineResult(notice="A revisão da transcrição foi cancelada; mantive a transcrição ao vivo.")
        except Exception as problem:
            return RefineResult(notice=f"Não consegui revisar a transcrição ({problem}); mantive a transcrição ao vivo.")

    def _channel(self, audio: Path, channel: str, language: str | None, detected: list, progress, cancel):
        found = info(audio)
        if found is None:
            return [], 0
        rate, lanes, frames = found
        index = CHANNELS.index(channel)
        reducer = _reducer(rate)
        window = WINDOW_SECONDS * SPEECH_RATE
        overlap = OVERLAP_SECONDS * SPEECH_RATE
        buffer = array("f")
        buffer_start = 0
        fresh = 0
        squares: list[float] = []
        pending = array("f")
        kept: list[RecognizedSpan] = []
        lost = 0
        done = 0

        def push_envelope(samples) -> None:
            nonlocal pending
            pending.extend(samples)
            size = int(0.5 * SPEECH_RATE)
            blocks = len(pending) // size
            squares.extend(mean_squares(pending, size))
            del pending[:blocks * size]

        def transcribe(samples, offset_samples: int) -> None:
            nonlocal lost
            while True:
                self._wait_for_idle(cancel)
                if cancel is not None and cancel.is_set():
                    raise Cancelled()
                try:
                    result = self.recognizer.transcribe(samples, language, should_stop=self.is_recording)
                    break
                except RecognitionInterrupted:
                    continue
            if detected[0] is None and result.language:
                detected[0] = result.language
            offset = offset_samples / SPEECH_RATE
            spans = [RecognizedSpan(s.text, s.start + offset, s.end + offset, s.confidence) for s in result.spans]
            envelope = ChannelEnvelope(squares + (mean_squares(pending, len(pending)) if len(pending) else []))
            good, dropped = filter_spans(spans, envelope, language or detected[0] or "pt")
            lost += dropped
            kept.extend(good)

        for block in read_blocks(audio, SAMPLE_RATE):
            out = reducer.process(block[index]) if index < len(block) else array("f")
            push_envelope(out)
            buffer.extend(out)
            fresh += len(out)
            done += len(block[0])
            progress(min(0.99, done / max(1, frames) * 0.99))
            while fresh >= window:
                transcribe(buffer, buffer_start)
                keep = min(overlap, len(buffer))
                buffer_start += len(buffer) - keep
                del buffer[:len(buffer) - keep]
                fresh = 0
        if fresh > 0 and len(buffer):
            transcribe(buffer, buffer_start)
        if channel == "mic":
            before = len(kept)
            kept = self._without_echo(audio, kept)
            lost += before - len(kept)
        return kept, lost

    def _without_echo(self, audio: Path, spans: list[RecognizedSpan]) -> list[RecognizedSpan]:
        out = []
        pad = self.bleed.pad_samples
        for span in spans:
            first = int(span.start * SPEECH_RATE)
            last = int(span.end * SPEECH_RATE)
            mic = window_16k(audio, 0, first, last)
            system = window_16k(audio, 1, first - pad, last + pad)
            if not BleedDetector.judge(mic, system, self.bleed):
                out.append(span)
        return out
