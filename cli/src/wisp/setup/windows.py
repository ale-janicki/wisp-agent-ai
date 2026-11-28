from pathlib import Path

from wisp.config import WispConfig, save_config
from wisp.doctor import claude_kind, locate_claude, locate_git
from wisp.fsops import ensure_dir
from wisp.paths import WispPaths
from wisp.report import Detail, StepReport
from wisp.runner import Runner, RunResult

CLAUDE_INSTALL_URL = "https://claude.ai/install.ps1"
CLAUDE_DOWNLOAD_FLAGS = ["--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2"]
GIT_ID = "Git.Git"
WINGET_CLAUDE_ID = "Anthropic.ClaudeCode"
WINGET_FLAGS = ["-e", "--source", "winget", "--accept-package-agreements", "--accept-source-agreements"]
GIT_SUMMARY = "Termine a instalação do Git na janela que abriu; o Wisp continua sozinho quando terminar"


class GitRunner:

    def __init__(self, runner: Runner, git: str):
        self._runner = runner
        self._git = git

    def run(self, argv, **kwargs) -> RunResult:
        args = list(argv)
        return self._runner.run([self._git, *args[1:]] if args and args[0] == "git" else args, **kwargs)


def _record(runner: Runner, details: list[Detail], argv: list[str], timeout: float) -> RunResult:
    result = runner.run(argv, timeout=timeout)
    details.append(Detail.capture(" ".join(argv), result.exit, result.stdout, result.stderr))
    return result


def _install_git(runner: Runner, details: list[Detail]) -> bool:
    argv = ["winget.exe", "install", "--id", GIT_ID, *WINGET_FLAGS]
    return _record(runner, details, argv, 900).exit == 0


def _install_claude(runner: Runner, paths: WispPaths, cfg: WispConfig, details: list[Detail]) -> Path | None:
    downloads = paths.state / "downloads"
    ensure_dir(downloads)
    script = downloads / "claude-install.ps1"
    try:
        fetched = _record(runner, details, ["curl.exe", *CLAUDE_DOWNLOAD_FLAGS, "-o", str(script), CLAUDE_INSTALL_URL], 120)
        ran = fetched.exit == 0 and _record(
            runner, details, ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(script)], 600
        ).exit == 0
    finally:
        script.unlink(missing_ok=True)
    if not ran:
        _record(runner, details, ["winget.exe", "install", "--id", WINGET_CLAUDE_ID, *WINGET_FLAGS], 600)
    return locate_claude(paths, cfg, runner)


def setup_system_windows(runner: Runner, paths: WispPaths, cfg: WispConfig, *, dry_run: bool) -> StepReport:
    details: list[Detail] = []
    git = locate_git(runner)
    claude = locate_claude(paths, cfg, runner)
    if dry_run:
        missing = [name for name, absent in (("git", git is None), ("claude", claude is None)) if absent]
        data = {"claude": str(claude)} if claude else {}
        return StepReport("system", "done", "dry run: nada foi instalado", data={**data, "missing": ",".join(missing)})

    changed = ""
    if git is None:
        if not _install_git(runner, details):
            return StepReport("system", "failed", "não consegui instalar o Git", details)
        if locate_git(runner) is None:
            return StepReport("system", "needs_user", GIT_SUMMARY, details, {"waiting": "git"})
        changed = "o Git foi instalado"
    if claude is None:
        claude = _install_claude(runner, paths, cfg, details)
        if claude is None:
            return StepReport("system", "failed", "não consegui instalar o Claude", details)
        changed = "o Claude foi instalado"
    version = _record(runner, details, [str(claude), "--version"], 10).stdout.strip()
    data = {"claude": str(claude), "claude_version": version, "claude_kind": claude_kind(claude)}
    if cfg.claude_bin != str(claude):
        cfg.claude_bin = str(claude)
        save_config(cfg)
    if changed:
        return StepReport("system", "done", changed, details, data)
    return StepReport("system", "skipped", "tudo pronto", details, data)
