import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.request
from dataclasses import replace

import pytest

from wisp.paths import WispPaths
from wisp.serve.features.settings import updates

MAC = {"tag_name": "v0.6.0", "prerelease": False, "draft": False, "assets": [{"name": "Wisp.dmg", "browser_download_url": "https://github.com/o/r/releases/download/v0.6.0/Wisp.dmg"}]}


def windows_release(version, *, prerelease=True, draft=False, asset="Wisp-Setup.exe", digest=None, extra=()):
    assets = [{"name": asset, "size": 12, "browser_download_url": f"https://github.com/ale-janicki/wisp-agent-ai/releases/download/windows-v{version}/{asset}",
               **({"digest": f"sha256:{digest}"} if digest else {})}, *extra]
    return {"tag_name": f"windows-v{version}", "html_url": f"https://github.com/o/r/releases/tag/windows-v{version}",
            "prerelease": prerelease, "draft": draft, "assets": assets}


def serve(monkeypatch, releases):
    seen = []

    def fake(url):
        seen.append(url)
        if isinstance(releases, Exception):
            raise releases
        return json.dumps(releases).encode()

    monkeypatch.setattr(updates, "fetch", fake)
    monkeypatch.setattr(updates, "fetch_page", lambda url: (fake(url), ""))
    return seen


def test_picks_the_newest_windows_prerelease_never_the_macs_latest(monkeypatch):
    seen = serve(monkeypatch, [MAC, windows_release("0.1.3"), windows_release("0.1.10"), windows_release("0.2.0", draft=True),
                               windows_release("0.3.0", prerelease=False), windows_release("0.1.9")])
    found = updates.check("0.1.0")["available"]
    assert found["version"] == "0.1.10" and found["tag"] == "windows-v0.1.10"
    assert found["asset"] == "Wisp-Setup.exe"
    assert seen == ["https://api.github.com/repos/ale-janicki/wisp-agent-ai/releases?per_page=100"]
    assert "latest" not in seen[0]


def test_up_to_date_or_no_windows_release_offers_nothing(monkeypatch):
    serve(monkeypatch, [MAC, windows_release("0.1.0")])
    assert updates.check("0.1.0") == {"ok": True, "available": None}
    assert updates.check("0.2.0") == {"ok": True, "available": None}
    serve(monkeypatch, [MAC])
    assert updates.check("0.0.1") == {"ok": True, "available": None}


def test_offline_or_garbage_is_an_error_not_a_crash(monkeypatch):
    serve(monkeypatch, urllib.error.URLError("down"))
    assert updates.check("0.1.0")["ok"] is False
    monkeypatch.setattr(updates, "fetch_page", lambda url: (b"{}", ""))
    assert updates.check("0.1.0") == {"ok": False, "error": "Não consegui verificar as atualizações. Tente de novo."}


def test_installer_prefers_the_setup_exe_and_carries_the_reported_digest(monkeypatch):
    other = {"name": "Wisp-portable.exe", "browser_download_url": "https://github.com/ale-janicki/wisp-agent-ai/releases/download/windows-v0.2.0/x.exe"}
    serve(monkeypatch, [windows_release("0.2.0", digest="ab" * 32, extra=[other]), ])
    found = updates.check("0.1.0")["available"]
    assert found["asset"] == "Wisp-Setup.exe" and found["verified"] is True


@pytest.mark.parametrize("url", ["https://github.com/o/r/a.exe", "https://objects.githubusercontent.com/a", "https://api.github.com/x"])
def test_allowed_hosts(url):
    assert updates.allowed(url)


@pytest.mark.parametrize("url", ["http://github.com/a", "https://evilgithub.com/a", "https://github.com.evil.io/a", "https://example.com/a", "github.com/a", "https://"])
def test_refused_hosts(url):
    assert not updates.allowed(url)


def paths(home):
    windows = WispPaths.for_os("Windows", home, {})
    return replace(windows, state=home / "state")


DATA = b"installer-bytes"
SHA = hashlib.sha256(DATA).hexdigest()
PIN = "https://github.com/ale-janicki/wisp-agent-ai/releases/download/windows-v"


def pinned_release(version="0.2.0", *, digest=None, sidecar=None, url=None):
    asset = {"name": "Wisp-Setup.exe", "size": 12, "browser_download_url": url or f"{PIN}{version}/Wisp-Setup.exe",
             **({"digest": f"sha256:{digest}"} if digest else {})}
    assets = [asset]
    if sidecar:
        assets.append({"name": "Wisp-Setup.exe.sha256", "browser_download_url": f"{PIN}{version}/Wisp-Setup.exe.sha256"})
    return {"tag_name": f"windows-v{version}", "html_url": "x", "prerelease": True, "draft": False, "assets": assets}


class Machine:

    def __init__(self, monkeypatch, releases, files=None):
        self.asked, self.ran, self.revealed = [], [], []
        files = files or {}

        def fetch(url):
            self.asked.append(url)
            if "/releases?" in url:
                return json.dumps(releases).encode()
            return files.get(url, DATA)

        monkeypatch.setattr(updates, "fetch", fetch)
        monkeypatch.setattr(updates, "fetch_page", lambda url: (fetch(url), ""))

    def install(self, home):
        return updates.install(paths(home), run=self.ran.append, reveal=self.revealed.append)


def test_install_runs_the_installer_only_after_the_published_digest_matches(fake_home, monkeypatch):
    machine = Machine(monkeypatch, [MAC, pinned_release(digest=SHA)])
    answer = machine.install(fake_home)
    target = fake_home / "state/downloads/Wisp-Setup.exe"
    assert answer == {"ok": True, "run": True, "path": str(target)}
    assert machine.ran == [str(target)] and machine.revealed == [] and target.read_bytes() == DATA
    assert machine.asked == ["https://api.github.com/repos/ale-janicki/wisp-agent-ai/releases?per_page=100", f"{PIN}0.2.0/Wisp-Setup.exe"]


def test_a_sha256_asset_next_to_the_exe_counts_as_the_digest(fake_home, monkeypatch):
    side = f"{PIN}0.2.0/Wisp-Setup.exe.sha256"
    machine = Machine(monkeypatch, [pinned_release(sidecar=True)], {side: f"{SHA}  Wisp-Setup.exe\n".encode()})
    assert machine.install(fake_home)["run"] is True and len(machine.ran) == 1


def test_a_malformed_sha256_asset_is_no_digest(fake_home, monkeypatch):
    side = f"{PIN}0.2.0/Wisp-Setup.exe.sha256"
    machine = Machine(monkeypatch, [pinned_release(sidecar=True)], {side: b"not a hash"})
    assert machine.install(fake_home)["run"] is False and machine.ran == []


def test_without_a_digest_the_file_is_kept_never_run_and_its_folder_is_opened(fake_home, monkeypatch):
    machine = Machine(monkeypatch, [pinned_release()])
    answer = machine.install(fake_home)
    target = fake_home / "state/downloads/Wisp-Setup.exe"
    assert answer["ok"] and answer["run"] is False and answer["path"] == str(target)
    assert target.exists() and machine.ran == [] and machine.revealed == [str(target)]


def test_a_hash_mismatch_deletes_the_file_and_runs_nothing(fake_home, monkeypatch):
    machine = Machine(monkeypatch, [pinned_release(digest="0" * 64)])
    answer = machine.install(fake_home)
    assert answer == {"ok": False, "error": "O arquivo baixado não confere com o publicado; foi apagado e não foi aberto."}
    assert not (fake_home / "state/downloads/Wisp-Setup.exe").exists()
    assert machine.ran == [] and machine.revealed == []


@pytest.mark.parametrize("url", [
    "https://github.com/evil/repo/releases/download/windows-v9.9.9/Wisp-Setup.exe",
    "https://github.com/ale-janicki/wisp-agent-ai-evil/releases/download/windows-v9/Wisp-Setup.exe",
    "https://github.com/ale-janicki/wisp-agent-ai/releases/download/v0.6.0/Wisp-Setup.exe",
    "https://github.com/ale-janicki/wisp-agent-ai/raw/main/Wisp-Setup.exe",
    "http://github.com/ale-janicki/wisp-agent-ai/releases/download/windows-v9/Wisp-Setup.exe",
])
def test_an_asset_outside_this_repositorys_windows_releases_is_refused_and_never_fetched(fake_home, monkeypatch, url):
    machine = Machine(monkeypatch, [pinned_release(digest=SHA, url=url)])
    answer = machine.install(fake_home)
    assert answer["ok"] is False
    assert machine.ran == [] and len(machine.asked) == 1 and not (fake_home / "state/downloads").exists()


def test_no_windows_release_means_nothing_to_install(fake_home, monkeypatch):
    machine = Machine(monkeypatch, [MAC])
    assert machine.install(fake_home)["ok"] is False and machine.ran == []


def test_check_does_not_hand_the_client_a_url_or_digest(monkeypatch):
    serve(monkeypatch, [pinned_release(digest=SHA)])
    found = updates.check("0.1.0")["available"]
    assert "url" not in found and "sha256" not in found and found["asset"] == "Wisp-Setup.exe" and found["verified"] is True


def _redirect(handler, target):
    request = urllib.request.Request("https://github.com/x")
    return handler.redirect_request(request, None, 302, "Found", {}, target)


def test_redirects_are_followed_only_to_allowed_https_hosts():
    guard = updates.GuardedRedirects()
    assert _redirect(guard, "https://objects.githubusercontent.com/blob?sig=1") is not None
    for bad in ("https://evil.example/x.exe", "http://objects.githubusercontent.com/x", "https://github.com.evil.io/x", "file:///C:/x.exe"):
        with pytest.raises(urllib.error.URLError):
            _redirect(guard, bad)


def test_the_real_opener_has_the_guard_installed():
    assert any(isinstance(h, updates.GuardedRedirects) for h in updates.opener().handlers)


def test_https_get_refuses_a_host_outside_github():
    with pytest.raises(ValueError):
        updates.https_get("https://example.com/x")


def test_the_environment_cannot_move_the_update_source(monkeypatch):
    monkeypatch.setenv("WISP_RELEASES_REPO", "someone/fork")
    seen = serve(monkeypatch, [])
    updates.check("0.1.0")
    assert "repos/someone/fork/releases" not in seen[0]
    assert f"repos/{updates.REPOSITORY}/releases" in seen[0]


def test_hash_is_checked_again_on_the_file_right_before_it_runs(fake_home, monkeypatch):
    machine = Machine(monkeypatch, [pinned_release(digest=SHA)])
    monkeypatch.setattr(updates, "file_sha256", lambda path: "f" * 64)
    answer = machine.install(fake_home)
    assert answer["ok"] is False and machine.ran == []
    assert not (fake_home / "state/downloads/Wisp-Setup.exe").exists()


def test_a_file_swapped_after_the_check_is_never_run(fake_home, monkeypatch):
    machine = Machine(monkeypatch, [pinned_release(digest=SHA)])
    real = updates.file_sha256

    def tampered(path):
        path.write_bytes(b"swapped")
        return real(path)

    monkeypatch.setattr(updates, "file_sha256", tampered)
    assert machine.install(fake_home)["ok"] is False and machine.ran == []


def test_a_disk_error_while_saving_is_a_friendly_error_not_a_crash(fake_home, monkeypatch):
    machine = Machine(monkeypatch, [pinned_release(digest=SHA)])

    def boom(self, data):
        raise OSError("disk full")

    monkeypatch.setattr(Path, "write_bytes", boom)
    assert machine.install(fake_home) == {"ok": False, "error": "Não consegui salvar a atualização no disco."}
    assert machine.ran == []


def test_the_repository_name_is_compared_without_case(fake_home, monkeypatch):
    url = "https://github.com/Ale-Janicki/Wisp-Agent-AI/releases/download/windows-v0.2.0/Wisp-Setup.exe"
    machine = Machine(monkeypatch, [pinned_release(digest=SHA, url=url)])
    assert machine.install(fake_home)["run"] is True
    assert updates.pinned(url) and not updates.pinned(url.replace("Agent-AI", "Agent-AI-evil"))


def _paged(monkeypatch, pages):
    asked = []

    def page(url):
        asked.append(url)
        body, link = pages[len(asked) - 1]
        return json.dumps(body).encode(), link

    monkeypatch.setattr(updates, "fetch_page", page)
    return asked


NEXT = '<https://api.github.com/repositories/1/releases?per_page=100&page={n}>; rel="next", <https://api.github.com/x?page=9>; rel="last"'


def test_releases_are_read_100_at_a_time_following_next_until_a_windows_one_turns_up(monkeypatch):
    asked = _paged(monkeypatch, [([MAC], NEXT.format(n=2)), ([MAC], NEXT.format(n=3)), ([windows_release("0.3.0")], "")])
    assert updates.check("0.1.0")["available"]["version"] == "0.3.0"
    assert asked[0].endswith("releases?per_page=100") and "page=2" in asked[1] and "page=3" in asked[2]


def test_paging_stops_after_five_pages(monkeypatch):
    asked = _paged(monkeypatch, [([MAC], NEXT.format(n=n + 2)) for n in range(8)])
    assert updates.check("0.1.0") == {"ok": True, "available": None}
    assert len(asked) == 5


def test_a_next_link_to_another_host_is_not_followed(monkeypatch):
    asked = _paged(monkeypatch, [([MAC], '<https://evil.example/releases?page=2>; rel="next"'), ([windows_release("0.3.0")], "")])
    assert updates.check("0.1.0") == {"ok": True, "available": None}
    assert len(asked) == 1
