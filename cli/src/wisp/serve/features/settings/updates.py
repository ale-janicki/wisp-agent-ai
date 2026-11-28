import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections.abc import Callable
from pathlib import Path

from wisp.fsops import ensure_dir
from wisp.paths import WispPaths

REPOSITORY = "ale-janicki/wisp-agent-ai"
TAG_PREFIX = "windows-v"
API_HOST = "api.github.com"
DOWNLOAD_HOSTS = ("github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com")
TIMEOUT = 20
PER_PAGE = 100
MAX_PAGES = 5
MAX_DOWNLOAD = 500 * 1024 * 1024
SHA256 = re.compile(r"\b[0-9a-fA-F]{64}\b")
VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)")

Fetch = Callable[[str], bytes]


def repository() -> str:
    return REPOSITORY


def allowed(url: str) -> bool:
    host = url.split("/")[2] if url.startswith("https://") and url.count("/") >= 3 else ""
    if "@" in host or ":" in host:
        return False
    return host == API_HOST or any(host == h or host.endswith("." + h) for h in DOWNLOAD_HOSTS)


class GuardedRedirects(urllib.request.HTTPRedirectHandler):

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not allowed(newurl):
            raise urllib.error.URLError(f"redirecionamento recusado: {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def opener() -> urllib.request.OpenerDirector:
    return urllib.request.build_opener(GuardedRedirects)


def https_get_page(url: str) -> tuple[bytes, str]:
    if not allowed(url):
        raise ValueError("endereço de atualização não permitido")
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "wisp-windows-updater"})
    with opener().open(request, timeout=TIMEOUT) as response:
        data = response.read(MAX_DOWNLOAD + 1)
        link = response.headers.get("Link") or ""
    if len(data) > MAX_DOWNLOAD:
        raise ValueError("arquivo grande demais")
    return data, link


def https_get(url: str) -> bytes:
    return https_get_page(url)[0]


def next_page(link: str) -> str | None:
    for part in link.split(","):
        match = re.match(r'\s*<([^>]+)>\s*;\s*rel="next"', part)
        if match and allowed(match.group(1)) and match.group(1).startswith(f"https://{API_HOST}/"):
            return match.group(1)
    return None


fetch: Fetch = https_get
fetch_page: Callable[[str], tuple[bytes, str]] = https_get_page


def parse_version(text: str) -> tuple[int, int, int] | None:
    match = VERSION.match(text.strip().removeprefix("v"))
    return None if match is None else (int(match.group(1)), int(match.group(2)), int(match.group(3)))


def newest_windows_release(releases: list[dict]) -> dict | None:
    candidates = []
    for release in releases:
        tag = release.get("tag_name")
        version = parse_version(tag.removeprefix(TAG_PREFIX)) if isinstance(tag, str) and tag.startswith(TAG_PREFIX) else None
        if version and release.get("prerelease") is True and release.get("draft") is not True:
            candidates.append((version, release))
    return max(candidates, key=lambda c: c[0])[1] if candidates else None


def installer_asset(release: dict) -> dict | None:
    assets = [a for a in release.get("assets") or [] if isinstance(a, dict) and isinstance(a.get("name"), str)
              and isinstance(a.get("browser_download_url"), str) and a["name"].lower().endswith(".exe")]
    return next((a for a in assets if "setup" in a["name"].lower()), assets[0] if assets else None)


def pinned(url: object) -> bool:
    prefix = f"https://github.com/{repository()}/releases/download/{TAG_PREFIX}"
    return isinstance(url, str) and url.lower().startswith(prefix.lower()) and allowed(url)


def newest(current: str | None = None) -> tuple[dict | None, dict | None, str | None]:
    release = None
    url: str | None = f"https://{API_HOST}/repos/{repository()}/releases?per_page={PER_PAGE}"
    try:
        for _ in range(MAX_PAGES):
            if url is None:
                break
            body, link = fetch_page(url)
            releases = json.loads(body)
            if not isinstance(releases, list):
                raise ValueError
            release = newest_windows_release([r for r in releases if isinstance(r, dict)])
            if release is not None:
                break
            url = next_page(link)
    except (OSError, ValueError, urllib.error.URLError):
        return None, None, "Não consegui verificar as atualizações. Tente de novo."
    if release is None:
        return None, None, None
    found = parse_version(release["tag_name"].removeprefix(TAG_PREFIX))
    have = parse_version(current) if current else None
    if found is None or (have is not None and found <= have):
        return None, None, None
    return release, installer_asset(release), None


def _digest(asset: dict) -> str | None:
    digest = asset.get("digest")
    return digest.removeprefix("sha256:").lower() if isinstance(digest, str) and digest.startswith("sha256:") and SHA256.fullmatch(digest[7:]) else None


def published_digest(release: dict, asset: dict) -> str | None:
    if (digest := _digest(asset)) is not None:
        return digest
    side = next((a for a in release.get("assets") or [] if isinstance(a, dict) and a.get("name") == f"{asset['name']}.sha256"), None)
    if side is None or not pinned(side.get("browser_download_url")):
        return None
    try:
        match = SHA256.search(fetch(side["browser_download_url"]).decode("utf-8", errors="replace"))
    except (OSError, ValueError, urllib.error.URLError):
        return None
    return match.group(0).lower() if match else None


def check(current: str) -> dict:
    release, asset, error = newest(current)
    if error:
        return {"ok": False, "error": error}
    if release is None:
        return {"ok": True, "available": None}
    version = release["tag_name"].removeprefix(TAG_PREFIX)
    usable = asset is not None and pinned(asset.get("browser_download_url"))
    return {"ok": True, "available": {
        "version": version, "tag": release["tag_name"], "notes_url": release.get("html_url"),
        "asset": asset["name"] if usable else None, "size": asset.get("size") if usable else None,
        "verified": bool(usable and published_digest(release, asset)),
    }}


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reveal_folder(path: str) -> None:
    if sys.platform == "win32":
        os.startfile(str(Path(path).parent))  # type: ignore[attr-defined]


def install(paths: WispPaths | None = None, run: Callable[[str], None] | None = None, reveal: Callable[[str], None] | None = None) -> dict:
    run, reveal = run or start_installer, reveal or reveal_folder
    release, asset, error = newest()
    if error:
        return {"ok": False, "error": error}
    if release is None or asset is None or not pinned(asset.get("browser_download_url")):
        return {"ok": False, "error": "Não há instalador do Windows para baixar."}
    digest = published_digest(release, asset)
    try:
        data = fetch(asset["browser_download_url"])
    except (OSError, ValueError, urllib.error.URLError):
        return {"ok": False, "error": "Não consegui baixar a atualização."}
    folder = Path((paths or WispPaths.current()).state) / "downloads"
    target = folder / (re.sub(r"[^A-Za-z0-9._-]", "_", asset["name"]) or "wisp-setup.exe")
    try:
        ensure_dir(folder)
        target.write_bytes(data)
    except OSError:
        return {"ok": False, "error": "Não consegui salvar a atualização no disco."}
    if digest is None:
        reveal(str(target))
        return {"ok": True, "run": False, "path": str(target)}
    if hashlib.sha256(data).hexdigest() != digest:
        target.unlink(missing_ok=True)
        return {"ok": False, "error": "O arquivo baixado não confere com o publicado; foi apagado e não foi aberto."}
    try:
        on_disk = file_sha256(target)
    except OSError:
        on_disk = ""
    if on_disk != digest:
        target.unlink(missing_ok=True)
        return {"ok": False, "error": "O arquivo baixado não confere com o publicado; foi apagado e não foi aberto."}
    run(str(target))
    return {"ok": True, "run": True, "path": str(target)}


def start_installer(path: str) -> None:
    if sys.platform == "win32":
        os.startfile(path)  # type: ignore[attr-defined]


def open_url(url: str) -> bool:
    base = f"https://github.com/{repository()}"
    if url != base and not url.startswith(base + "/"):
        return False
    import webbrowser

    return webbrowser.open(url)
