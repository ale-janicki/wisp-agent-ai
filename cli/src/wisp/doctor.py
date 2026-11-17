import json
import os
import platform
from dataclasses import dataclass, field
from pathlib import Path

from wisp.config import WispConfig
from wisp.jobs import JobState, NotSupportedHere, manager_for
from wisp.paths import WispPaths
from wisp.runner import Runner

BOT_LABEL = "ai.wisp.bot"
MIN_MACOS = 15


@dataclass
class Check:
    id: str
    ok: bool
    summary: str
    step: str | None
    data: dict[str, str] = field(default_factory=dict)


def locate_claude(paths: WispPaths, cfg: WispConfig, runner: Runner) -> Path | None:
    candidates = [
        *([Path(cfg.claude_bin)] if cfg.claude_bin else []),
        paths.home / ".local/bin/claude",
        Path("/opt/homebrew/bin/claude"),
        Path("/usr/local/bin/claude"),
    ]
    for candidate in candidates:
        if runner.run([str(candidate), "--version"], timeout=10).exit == 0:
            return candidate
    return None


def _check_os(runner: Runner, **_) -> Check:
    result = runner.run(["sw_vers", "-productVersion"], timeout=10)
    version = result.stdout.strip()
    major = version.split(".")[0]
    ok = result.exit == 0 and major.isdigit() and int(major) >= MIN_MACOS
    summary = f"macOS {version}" if ok else f"o Wisp pede macOS {MIN_MACOS} ou mais"
    return Check("os", ok, summary, None, {"version": version} if version else {})


def _check_clt(runner: Runner, **_) -> Check:
    ok = runner.run(["xcode-select", "-p"], timeout=10).exit == 0
    return Check("clt", ok, "Ferramentas de linha de comando instaladas" if ok else "faltam as Ferramentas de linha de comando", "system")


def _check_claude(runner: Runner, paths: WispPaths, cfg: WispConfig, **_) -> Check:
    found = locate_claude(paths, cfg, runner)
    if found is None:
        return Check("claude", False, "o Claude Code não está instalado", "system")
    return Check("claude", True, "Claude Code instalado", "system", {"path": str(found)})


def _check_claude_login(runner: Runner, paths: WispPaths, cfg: WispConfig, **_) -> Check:
    not_in = Check("claude_login", False, "você ainda não entrou no Claude", "login")
    found = locate_claude(paths, cfg, runner)
    if found is None:
        return not_in
    result = runner.run([str(found), "auth", "status", "--json"], timeout=10)
    try:
        status = json.loads(result.stdout)
    except json.JSONDecodeError:
        return not_in
    if result.exit != 0 or not isinstance(status, dict) or status.get("loggedIn") is not True:
        return not_in
    data = {key: str(status.get(key, "")) for key in ("authMethod", "subscriptionType")}
    return Check("claude_login", True, "você está dentro do Claude", "login", data)


def _check_homebrew(runner: Runner, **_) -> Check:
    ok = any(runner.run([brew, "--version"], timeout=10).exit == 0 for brew in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew"))
    return Check("homebrew", ok, "Homebrew instalado" if ok else "Homebrew não instalado (opcional)", None)


def _check_brain(cfg: WispConfig, **_) -> Check:
    ok = bool(cfg.brain) and Path(cfg.brain).is_dir()
    return Check("brain", ok, "cérebro pronto" if ok else "o cérebro ainda não foi criado", "brain")


def _check_harness(paths: WispPaths, **_) -> Check:
    ok = (paths.config / "harness-installed.json").exists()
    return Check("harness", ok, "ferramentas do Claude instaladas" if ok else "as ferramentas do Claude ainda não foram instaladas", "harness")


def _check_telegram(runner: Runner, paths: WispPaths, cfg: WispConfig, **_) -> Check:
    if cfg.telegram is None:
        return Check("telegram", True, "opcional, não configurado", "telegram")
    try:
        state = manager_for(platform.system(), paths, runner, os.getuid()).state(BOT_LABEL)
    except NotSupportedHere:
        return Check("telegram", False, "o Telegram ainda não roda neste sistema", "telegram")
    ok = state == JobState.RUNNING
    return Check("telegram", ok, "Telegram conectado" if ok else "o Telegram está configurado mas parado", "telegram", {"job": state.value})


def _check_profile(paths: WispPaths, **_) -> Check:
    profile = paths.config / "profile.json"
    if profile.is_symlink():
        return Check("profile", True, "perfil gerenciado fora do Wisp", "profile")
    ok = profile.exists()
    return Check("profile", ok, "perfil pronto" if ok else "o perfil ainda não foi criado", "profile")


_CHECKS = {
    "os": _check_os,
    "clt": _check_clt,
    "claude": _check_claude,
    "claude_login": _check_claude_login,
    "homebrew": _check_homebrew,
    "brain": _check_brain,
    "harness": _check_harness,
    "telegram": _check_telegram,
    "profile": _check_profile,
}


def run_doctor(runner: Runner, paths: WispPaths, cfg: WispConfig, only: set[str] | None = None) -> list[Check]:
    return [check(runner=runner, paths=paths, cfg=cfg) for id, check in _CHECKS.items() if only is None or id in only]
