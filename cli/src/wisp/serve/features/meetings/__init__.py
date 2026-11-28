from __future__ import annotations

import asyncio
import atexit

from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, Response
from starlette.routing import Route

from wisp.serve.features.meetings import service
from wisp.serve.features.meetings.service import Conflict, Forbidden, Invalid, MeetingsService, NotFound


def _service(request: Request) -> MeetingsService:
    app = request.app
    current = getattr(app.state, "meetings", None)
    if current is None:
        current = MeetingsService(app.state.host, service.ENV_FACTORY())
        app.state.meetings = current
        atexit.register(current.close)
    current.bind_loop(asyncio.get_running_loop())
    return current


async def _body(request: Request) -> dict:
    try:
        body = await request.json()
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


def _guard(call):
    async def handler(request: Request) -> Response:
        svc = _service(request)
        body = await _body(request) if request.method in ("POST", "PUT", "PATCH") else {}
        try:
            result = await asyncio.to_thread(call, svc, request, body)
        except NotFound as problem:
            return JSONResponse({"error": str(problem)}, status_code=404)
        except Forbidden as problem:
            return JSONResponse({"error": str(problem)}, status_code=403)
        except Conflict as problem:
            return JSONResponse({"error": str(problem)}, status_code=409)
        except Invalid as problem:
            return JSONResponse({"error": str(problem)}, status_code=400)
        except Exception as problem:
            return JSONResponse({"error": str(problem) or problem.__class__.__name__}, status_code=500)
        return JSONResponse(result if result is not None else {"ok": True})

    return handler


def _text(body: dict, key: str, default: str = "") -> str:
    value = body.get(key, default)
    return value if isinstance(value, str) else default


def _bool(body: dict, key: str):
    value = body.get(key)
    return value if isinstance(value, bool) else None


async def audio(request: Request) -> Response:
    svc = _service(request)
    try:
        path = svc.audio_file(request.path_params["id"])
    except NotFound as problem:
        return JSONResponse({"error": str(problem)}, status_code=404)
    return FileResponse(path, media_type="audio/wav")


routes = [
    Route("/state", _guard(lambda s, r, b: s.state()), methods=["GET"]),
    Route("/meetings", _guard(lambda s, r, b: s.list_meetings()), methods=["GET"]),
    Route("/meetings/{id}", _guard(lambda s, r, b: s.meeting(r.path_params["id"])), methods=["GET"]),
    Route("/meetings/{id}/audio", audio, methods=["GET"]),
    Route("/meetings/{id}/note", _guard(lambda s, r, b: s.generate_note(r.path_params["id"])), methods=["POST"]),
    Route("/meetings/{id}/improve", _guard(lambda s, r, b: s.improve_transcript(r.path_params["id"])), methods=["POST"]),
    Route("/meetings/{id}/retry", _guard(lambda s, r, b: s.retry(r.path_params["id"])), methods=["POST"]),
    Route("/meetings/{id}/cancel", _guard(lambda s, r, b: s.cancel_job(r.path_params["id"])), methods=["POST"]),
    Route("/meetings/{id}/brain", _guard(lambda s, r, b: s.save_to_brain(r.path_params["id"], b.get("recreate") is True)),
          methods=["POST"]),
    Route("/meetings/{id}/open-folder", _guard(lambda s, r, b: s.open_folder(r.path_params["id"])), methods=["POST"]),
    Route("/meetings/{id}/open-brain-note", _guard(lambda s, r, b: s.open_brain_note(r.path_params["id"])), methods=["POST"]),
    Route("/meetings/{id}/webhook/confirm", _guard(lambda s, r, b: s.confirm_webhook(r.path_params["id"])), methods=["POST"]),
    Route("/meetings/{id}/webhook/allow",
          _guard(lambda s, r, b: s.allow_webhook(r.path_params["id"], b.get("confirm") if isinstance(b.get("confirm"), str) else None)),
          methods=["POST"]),
    Route("/meetings/{id}/webhook/dismiss", _guard(lambda s, r, b: s.dismiss_webhook(r.path_params["id"])), methods=["POST"]),
    Route("/record/start", _guard(lambda s, r, b: s.start(b.get("sources") if isinstance(b.get("sources"), str) else None)),
          methods=["POST"]),
    Route("/record/stop", _guard(lambda s, r, b: s.stop()), methods=["POST"]),
    Route("/record/pause", _guard(lambda s, r, b: s.pause()), methods=["POST"]),
    Route("/record/resume", _guard(lambda s, r, b: s.resume()), methods=["POST"]),
    Route("/record/bookmark", _guard(lambda s, r, b: s.bookmark(_text(b, "label"))), methods=["POST"]),
    Route("/record/sources", _guard(lambda s, r, b: s.set_sources(_text(b, "sources"))), methods=["PUT"]),
    Route("/record/message/dismiss", _guard(lambda s, r, b: s.dismiss_message()), methods=["POST"]),
    Route("/models", _guard(lambda s, r, b: s.models()), methods=["GET"]),
    Route("/models/{id}/download", _guard(lambda s, r, b: s.download_model(r.path_params["id"])), methods=["POST"]),
    Route("/models/{id}/cancel", _guard(lambda s, r, b: s.cancel_download(r.path_params["id"])), methods=["POST"]),
    Route("/settings", _guard(lambda s, r, b: s.get_settings()), methods=["GET"]),
    Route("/settings", _guard(lambda s, r, b: s.put_settings(b)), methods=["PUT"]),
    Route("/webhook", _guard(lambda s, r, b: s.webhook_config()), methods=["GET"]),
    Route("/webhook", _guard(lambda s, r, b: s.put_webhook(
        b.get("url") if isinstance(b.get("url"), str) else None, _bool(b, "enabled"), _bool(b, "signs"))), methods=["PUT"]),
    Route("/webhook/secret", _guard(lambda s, r, b: s.webhook_secret()), methods=["GET"]),
    Route("/copilot", _guard(lambda s, r, b: s.set_copilot(**{k: v for k, v in b.items() if k in (
        "assist", "lookup", "lookup_others", "nudges")})), methods=["PUT"]),
    Route("/copilot/nudge/dismiss", _guard(lambda s, r, b: s.dismiss_nudge()), methods=["POST"]),
    Route("/copilot/prep", _guard(lambda s, r, b: s.prepare(_text(b, "title"), _text(b, "description"))), methods=["POST"]),
    Route("/copilot/checklist/{item}", _guard(lambda s, r, b: s.toggle_check(r.path_params["item"], b.get("done") is True)),
          methods=["PUT"]),
]
