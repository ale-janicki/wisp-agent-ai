from __future__ import annotations

import base64
import re
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from typing import Protocol

ACTIONS = ("previous", "playpause", "next")
MAX_ARTWORK_BYTES = 5_000_000
KNOWN_PLAYERS = {"spotify": "Spotify", "zunemusic": "Media Player", "music.ui": "Media Player", "chrome": "Chrome",
                 "msedge": "Edge", "firefox": "Firefox", "brave": "Brave", "vlc": "VLC", "itunes": "iTunes",
                 "applemusic": "Apple Music"}


@dataclass
class NowPlaying:
    player: str
    title: str
    artist: str
    album: str
    is_playing: bool
    position: float
    duration: float
    key: str

    def as_json(self) -> dict:
        return asdict(self)


class MediaBackend(Protocol):
    async def now(self) -> NowPlaying | None: ...
    async def control(self, action: str) -> bool: ...
    async def artwork(self) -> bytes | None: ...


def player_name(app_id: str) -> str:
    lowered = app_id.lower()
    for marker, name in KNOWN_PLAYERS.items():
        if marker in lowered:
            return name
    tail = re.split(r"[!\\/]", app_id)[-1]
    stem = re.sub(r"\.exe$", "", tail, flags=re.IGNORECASE).split(".")[-1]
    return stem[:1].upper() + stem[1:] if stem else "Mídia"


def estimate_position(position: float, duration: float, playing: bool, updated: datetime | None,
                      now: datetime | None = None) -> float:
    if playing and updated is not None:
        now = now or datetime.now(timezone.utc)
        if updated.tzinfo is None:
            updated = updated.replace(tzinfo=timezone.utc)
        position += max(0.0, (now - updated).total_seconds())
    return min(max(0.0, position), max(0.0, duration))


def artwork_data_url(data: bytes | None) -> str | None:
    if not data or len(data) > MAX_ARTWORK_BYTES:
        return None
    mime = "image/png" if data.startswith(b"\x89PNG") else "image/jpeg" if data.startswith(b"\xff\xd8") else (
        "image/bmp" if data.startswith(b"BM") else None)
    return f"data:{mime};base64,{base64.b64encode(data).decode()}" if mime else None


class WindowsMedia:
    async def _session(self):
        from winrt.windows.media.control import GlobalSystemMediaTransportControlsSessionManager as Manager
        manager = await Manager.request_async()
        return manager.get_current_session()

    async def now(self) -> NowPlaying | None:
        from winrt.windows.media.control import GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status
        session = await self._session()
        if session is None:
            return None
        props = await session.try_get_media_properties_async()
        title = (props.title or "").strip()
        if not title:
            return None
        info, timeline = session.get_playback_info(), session.get_timeline_properties()
        playing = info.playback_status == Status.PLAYING
        start = _seconds(timeline.start_time)
        duration = max(0.0, _seconds(timeline.end_time) - start)
        position = estimate_position(_seconds(timeline.position) - start, duration, playing,
                                     getattr(timeline, "last_updated_time", None))
        return NowPlaying(player_name(session.source_app_user_model_id), title, props.artist or "",
                          props.album_title or "", playing, position, duration,
                          f"{session.source_app_user_model_id}|{title}|{props.artist}")

    async def control(self, action: str) -> bool:
        session = await self._session()
        if session is None:
            return False
        call = {"previous": session.try_skip_previous_async, "playpause": session.try_toggle_play_pause_async,
                "next": session.try_skip_next_async}[action]
        return bool(await call())

    async def artwork(self) -> bytes | None:
        from winrt.windows.storage.streams import Buffer, DataReader, InputStreamOptions
        session = await self._session()
        if session is None:
            return None
        props = await session.try_get_media_properties_async()
        if props.thumbnail is None:
            return None
        stream = await props.thumbnail.open_read_async()
        buffer = Buffer(MAX_ARTWORK_BYTES)
        await stream.read_async(buffer, buffer.capacity, InputStreamOptions.READ_AHEAD)
        reader = DataReader.from_buffer(buffer)
        data = bytearray(reader.unconsumed_buffer_length)
        reader.read_bytes(data)
        return bytes(data) or None


def _seconds(value) -> float:
    return value.total_seconds() if isinstance(value, timedelta) else float(value or 0)


def default_backend() -> MediaBackend | None:
    if sys.platform != "win32":
        return None
    try:
        import winrt.windows.media.control  # noqa: F401
    except ImportError:
        return None
    return WindowsMedia()
