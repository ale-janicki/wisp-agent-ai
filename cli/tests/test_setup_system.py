import json

from wisp.config import WispConfig, load_config
from wisp.paths import WispPaths
from wisp.runner import FakeRunner, RunResult
from wisp.setup.system import setup_system

OK = RunResult([], 0, "", "")
API = "https://api.github.com/repos/Homebrew/brew/releases/latest"
PKG_URL = "https://github.com/Homebrew/brew/releases/download/9.9.9/Homebrew.pkg"


def _paths(home):
    return WispPaths.for_os("Darwin", home, {})


def _script(home, *, clt=True, claude=True, brew=False, extra=None):
    script = {}
    if clt:
        script[("xcode-select", "-p")] = OK
    if claude:
        script[(str(home / ".local/bin/claude"), "--version")] = RunResult([], 0, "2.1.0 (Claude Code)\n", "")
    if brew:
        script[("/opt/homebrew/bin/brew", "--version")] = OK
    script.update(extra or {})
    return script


def _release(name="Homebrew.pkg", url=PKG_URL):
    return RunResult([], 0, json.dumps({"assets": [{"name": name, "browser_download_url": url}]}), "")


SIG_STATUS = "Status: signed by a developer certificate issued by Apple for distribution\n"


def _sig(leaf="1. Developer ID Installer: Someone (927JGANW46)", status=SIG_STATUS):
    return f'Package "Homebrew.pkg":\n   {status}   Certificate Chain:\n    {leaf}\n    2. Developer ID Certification Authority\n'


GOOD_SIGNATURE = _sig()


def _brew_script(home, signature):
    return _script(home, extra={
        ("curl", "-fsSL", API): _release(),
        ("curl", "-fsSL", "-o"): OK,
        ("pkgutil", "--check-signature"): RunResult([], 0, signature, ""),
        ("open",): OK,
    })


class InstallingRunner(FakeRunner):
    def __init__(self, home, installer: RunResult):
        super().__init__(_script(home, claude=False, extra={("curl", "--fail"): OK, ("/bin/bash",): installer}))
        self.claude = home / ".local/bin/claude"
        self.installer = installer

    def run(self, argv, **kw):
        result = super().run(argv, **kw)
        if argv[:1] == ["/bin/bash"] and self.installer.exit == 0:
            self.script[(str(self.claude), "--version")] = RunResult([], 0, "2.1.0\n", "")
        return result


def _run(runner, home, cfg=None, *, with_homebrew=False, dry_run=False):
    return setup_system(runner, _paths(home), cfg or WispConfig(), with_homebrew=with_homebrew, dry_run=dry_run)


def test_all_present_is_skipped(fake_home):
    runner = FakeRunner(_script(fake_home))
    report = _run(runner, fake_home)
    assert report.status == "skipped"
    assert report.data == {"claude": str(fake_home / ".local/bin/claude"), "claude_version": "2.1.0 (Claude Code)"}
    assert load_config().claude_bin == str(fake_home / ".local/bin/claude")
    assert not any("curl" in " ".join(c) for c in runner.calls)


def test_clt_missing_opens_installer_and_needs_user(fake_home):
    runner = FakeRunner(_script(fake_home, clt=False, extra={("xcode-select", "--install"): OK}))
    report = _run(runner, fake_home)
    assert report.status == "needs_user"
    assert report.summary == "Clique em Instalar na janela da Apple; o Wisp continua sozinho quando terminar"
    assert ["xcode-select", "--install"] in runner.calls
    assert report.data == {"waiting": "clt"}
    assert not any("claude" in " ".join(c) for c in runner.calls)


def test_claude_missing_runs_official_installer(fake_home):
    runner = InstallingRunner(fake_home, OK)
    report = _run(runner, fake_home)
    download = next(c for c in runner.calls if c[:1] == ["curl"])
    script = str(fake_home / ".local/state/wisp/downloads/claude-install.sh")
    assert download[-1] == "https://claude.ai/install.sh"
    assert {"--fail", "--tlsv1.2"} <= set(download) and download[download.index("--proto") + 1] == "=https"
    assert download[download.index("-o") + 1] == script
    assert runner.calls.index(download) < runner.calls.index(["/bin/bash", script])
    assert not any("|" in " ".join(c) or c[:2] == ["/bin/bash", "-c"] for c in runner.calls)
    assert not (fake_home / ".local/state/wisp/downloads/claude-install.sh").exists()
    assert report.status == "done" and report.summary == "o Claude foi instalado"
    assert report.data["claude"] == str(fake_home / ".local/bin/claude")
    assert load_config().claude_bin == str(fake_home / ".local/bin/claude")


def test_claude_download_failure_never_runs_the_script(fake_home):
    runner = InstallingRunner(fake_home, OK)
    runner.script[("curl", "--fail")] = RunResult([], 22, "", "curl: (22) The requested URL returned error: 404")
    report = _run(runner, fake_home)
    assert report.status == "failed"
    assert not any(c[:1] == ["/bin/bash"] for c in runner.calls)


def test_claude_install_failure_is_failed_with_output(fake_home):
    runner = InstallingRunner(fake_home, RunResult([], 1, "", "curl: (6) could not resolve host"))
    report = _run(runner, fake_home)
    assert report.status == "failed" and report.summary == "não consegui instalar o Claude"
    assert "could not resolve host" in " ".join(d.output for d in report.details)
    assert load_config().claude_bin is None


def test_homebrew_only_when_asked(fake_home):
    runner = FakeRunner(_brew_script(fake_home, GOOD_SIGNATURE))
    assert _run(runner, fake_home).status == "skipped"
    assert not any(c[0] in ("pkgutil", "open") or API in c for c in runner.calls)
    asked = FakeRunner(_brew_script(fake_home, GOOD_SIGNATURE))
    report = _run(asked, fake_home, with_homebrew=True)
    assert report.status == "needs_user"
    assert report.summary == "O instalador do Homebrew vai pedir a senha do seu Mac"
    assert report.data["waiting"] == "homebrew"
    assert ["open", str(fake_home / ".local/state/wisp/downloads/Homebrew.pkg")] in asked.calls
    assert (fake_home / ".local/state/wisp/downloads").is_dir()


def test_homebrew_already_installed_is_skipped(fake_home):
    runner = FakeRunner(_script(fake_home, brew=True))
    assert _run(runner, fake_home, with_homebrew=True).status == "skipped"
    assert not any(API in c for c in runner.calls)


def test_homebrew_pkg_bad_signature_refused(fake_home):
    for signature in ("Status: no signature", "1. Developer ID Installer: Someone Else (AAAAAAAAAA)"):
        runner = FakeRunner(_brew_script(fake_home, signature))
        report = _run(runner, fake_home, with_homebrew=True)
        assert report.status == "failed"
        assert not any(c[0] == "open" for c in runner.calls)


def test_homebrew_asset_from_another_host_refused(fake_home):
    script = _brew_script(fake_home, GOOD_SIGNATURE)
    script[("curl", "-fsSL", API)] = _release(url="https://example.com/Homebrew.pkg")
    runner = FakeRunner(script)
    assert _run(runner, fake_home, with_homebrew=True).status == "failed"
    assert not any(c[0] in ("pkgutil", "open") for c in runner.calls)


def test_dry_run_runs_nothing(fake_home):
    runner = FakeRunner(_script(fake_home, claude=False))
    report = _run(runner, fake_home, with_homebrew=True, dry_run=True)
    assert report.status == "done"
    assert report.data["missing"] == "claude,homebrew"
    assert all(c[1:2] == ["--version"] or c[:2] == ["xcode-select", "-p"] for c in runner.calls)
    assert not (fake_home / ".local/state/wisp").exists()
    assert not (fake_home / ".config/wisp").exists()


def test_signature_must_be_parsed_not_substring_matched(fake_home):
    bad = [
        _sig(leaf="1. Developer ID Application: Someone (927JGANW46)"),
        _sig(leaf="1. Developer ID Installer: Evil (927JGANW46) Corp (AAAAAAAAAA)"),
        _sig(status="Status: no signature\n"),
        'Developer ID Installer: elsewhere\n   1. Other: Someone (927JGANW46)\n' + SIG_STATUS,
        _sig(leaf="2. Developer ID Installer: Someone (927JGANW46)"),
    ]
    for signature in bad:
        runner = FakeRunner(_brew_script(fake_home, signature))
        assert _run(runner, fake_home, with_homebrew=True).status == "failed", signature
        assert not any(c[0] == "open" for c in runner.calls)


def test_clt_install_failure_is_failed_with_output(fake_home):
    failing = RunResult([], 1, "", "xcode-select: error: no GUI session")
    runner = FakeRunner(_script(fake_home, clt=False, extra={("xcode-select", "--install"): failing}))
    report = _run(runner, fake_home)
    assert report.status == "failed"
    assert "no GUI session" in " ".join(d.output for d in report.details)


def test_clt_install_already_requested_stays_needs_user(fake_home):
    requested = RunResult([], 1, "", "xcode-select: note: install requested for command line developer tools")
    runner = FakeRunner(_script(fake_home, clt=False, extra={("xcode-select", "--install"): requested}))
    assert _run(runner, fake_home).status == "needs_user"


def test_malformed_homebrew_asset_is_failed_not_a_traceback(fake_home):
    script = _brew_script(fake_home, _sig())
    script[("curl", "-fsSL", API)] = RunResult([], 0, json.dumps({"assets": [{"nome": "x"}, 7]}), "")
    runner = FakeRunner(script)
    assert _run(runner, fake_home, with_homebrew=True).status == "failed"
    assert not any(c[0] in ("pkgutil", "open") for c in runner.calls)


def test_installer_script_exits_zero_but_claude_still_missing(fake_home):
    runner = FakeRunner(_script(fake_home, claude=False, extra={("curl", "--fail"): OK, ("/bin/bash",): RunResult([], 0, "", "curl: (6) could not resolve host")}))
    report = _run(runner, fake_home)
    assert report.status == "failed"
    assert "could not resolve host" in " ".join(d.output for d in report.details)
