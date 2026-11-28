import json
import os
import platform
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path, PureWindowsPath

from wisp import compat
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


WINDOWS_VERSION = re.compile(r"\[Version (\d+)\.(\d+)\.(\d+)")
MIN_WINDOWS = 10
NPM_CLAUDE = "node_modules/@anthropic-ai/claude-code/bin/claude.exe"


def is_windows(paths: WispPaths) -> bool:
    if paths.system:
        return paths.system == "Windows"
    return isinstance(paths.config, PureWindowsPath)


def _npm_dir(paths: WispPaths):
    return paths.config.parent / "npm"


def _claude_candidates_windows(paths: WispPaths, cfg: WispConfig) -> list[Path]:
    found = shutil.which("claude.exe")
    return [
        *([Path(cfg.claude_bin)] if cfg.claude_bin else []),
        paths.home / ".local/bin/claude.exe",
        Path(str(_npm_dir(paths) / NPM_CLAUDE)),
        *([Path(found)] if found else []),
    ]


def locate_git(runner: Runner) -> str | None:
    roots = [os.environ.get(name) for name in ("ProgramFiles", "ProgramFiles(x86)")]
    local = os.environ.get("LOCALAPPDATA")
    candidates = ["git", *(f"{root}\\Git\\cmd\\git.exe" for root in roots if root),
                  *([f"{local}\\Programs\\Git\\cmd\\git.exe"] if local else [])]
    return next((c for c in candidates if runner.run([c, "--version"], timeout=10).exit == 0), None)


def locate_claude(paths: WispPaths, cfg: WispConfig, runner: Runner) -> Path | None:
    if is_windows(paths):
        return next((c for c in _claude_candidates_windows(paths, cfg) if runner.run([str(c), "--version"], timeout=10).exit == 0), None)
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


def locate_codex(paths: WispPaths, cfg: WispConfig, runner: Runner) -> Path | None:
    if is_windows(paths):
        windows = [
            *([Path(cfg.codex_bin)] if cfg.codex_bin else []),
            paths.home / ".local/bin/codex.exe",
            paths.home / ".bun/bin/codex.exe",
            Path(str(_npm_dir(paths) / "codex.cmd")),
        ]
        return next((c for c in windows if runner.run([str(c), "--version"], timeout=10).exit == 0), None)
    candidates = [
        *([Path(cfg.codex_bin)] if cfg.codex_bin else []),
        paths.home / ".local/bin/codex",
        paths.home / ".npm-global/bin/codex",
        paths.home / ".bun/bin/codex",
        Path("/opt/homebrew/bin/codex"),
        Path("/usr/local/bin/codex"),
    ]
    for candidate in candidates:
        if runner.run([str(candidate), "--version"], timeout=10).exit == 0:
            return candidate
    return None


def _check_os(runner: Runner, paths: WispPaths | None = None, **_) -> Check:
    if paths is not None and is_windows(paths):
        return _check_os_windows(runner)
    result = runner.run(["sw_vers", "-productVersion"], timeout=10)
    version = result.stdout.strip()
    major = version.split(".")[0]
    ok = result.exit == 0 and major.isdigit() and int(major) >= MIN_MACOS
    summary = f"macOS {version}" if ok else f"o Wisp pede macOS {MIN_MACOS} ou mais"
    return Check("os", ok, summary, None, {"version": version} if version else {})


def _check_os_windows(runner: Runner) -> Check:
    result = runner.run(["cmd.exe", "/c", "ver"], timeout=10)
    match = WINDOWS_VERSION.search(result.stdout)
    ok = result.exit == 0 and match is not None and int(match.group(1)) >= MIN_WINDOWS
    if ok:
        return Check("os", True, f"Windows {match.group(1)}.{match.group(2)}.{match.group(3)}", None, {"version": ".".join(match.groups())})
    return Check("os", False, f"o Wisp pede Windows {MIN_WINDOWS} ou mais", None)


def _check_git(runner: Runner, **_) -> Check:
    found = locate_git(runner)
    if found is None:
        return Check("git", False, "falta o Git", "system")
    return Check("git", True, "Git instalado", "system", {"path": found})


def claude_kind(path: Path | str) -> str:
    text = str(path).replace("\\", "/").lower()
    if text.endswith((".cmd", ".bat")):
        return "npm-shim"
    return "npm" if "/node_modules/" in text else "native"


def _check_claude_windows(runner: Runner, paths: WispPaths, cfg: WispConfig) -> Check:
    found = locate_claude(paths, cfg, runner)
    if found is not None:
        return Check("claude", True, "o Claude está instalado", "system", {"path": str(found), "kind": claude_kind(found)})
    shim = str(_npm_dir(paths) / "claude.cmd")
    if runner.run([shim, "--version"], timeout=10).exit == 0:
        return Check("claude", False, "o Claude veio pelo npm só com atalho .cmd; falta a versão nativa", "system",
                     {"path": shim, "kind": "npm-shim"})
    return Check("claude", False, "o Claude não está instalado", "system")


def _check_clt(runner: Runner, **_) -> Check:
    ok = runner.run(["xcode-select", "-p"], timeout=10).exit == 0
    return Check("clt", ok, "Ferramentas de linha de comando instaladas" if ok else "faltam as Ferramentas de linha de comando", "system")


def _check_claude(runner: Runner, paths: WispPaths, cfg: WispConfig, **_) -> Check:
    if is_windows(paths):
        return _check_claude_windows(runner, paths, cfg)
    found = locate_claude(paths, cfg, runner)
    if found is None:
        return Check("claude", False, "o Claude não está instalado", "system")
    return Check("claude", True, "o Claude está instalado", "system", {"path": str(found)})


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


def _check_codex(runner: Runner, paths: WispPaths, cfg: WispConfig, **_) -> Check:
    found = locate_codex(paths, cfg, runner)
    if found is None:
        return Check("codex", False, "o Codex não está instalado (opcional)", None)
    return Check("codex", True, "o Codex está instalado", None, {"path": str(found)})


def _check_codex_login(runner: Runner, paths: WispPaths, cfg: WispConfig, **_) -> Check:
    found = locate_codex(paths, cfg, runner)
    if found is None or runner.run([str(found), "login", "status"], timeout=10).exit != 0:
        return Check("codex_login", False, "você ainda não entrou no Codex (opcional)", None)
    return Check("codex_login", True, "você está dentro do Codex", None)


def _check_homebrew(runner: Runner, **_) -> Check:
    ok = any(runner.run([brew, "--version"], timeout=10).exit == 0 for brew in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew"))
    return Check("homebrew", ok, "Homebrew instalado" if ok else "Homebrew não instalado (opcional)", None)


def _check_brain(cfg: WispConfig, **_) -> Check:
    ok = bool(cfg.brain) and Path(cfg.brain).expanduser().is_dir()
    return Check("brain", ok, "cérebro pronto" if ok else "o cérebro ainda não foi criado", "brain")


def _check_harness(paths: WispPaths, **_) -> Check:
    ok = Path(str(paths.config / "harness-installed.json")).exists()
    return Check("harness", ok, "ferramentas do Claude instaladas" if ok else "as ferramentas do Claude ainda não foram instaladas", "harness")


def _check_telegram(runner: Runner, paths: WispPaths, cfg: WispConfig, **_) -> Check:
    if cfg.telegram is None:
        return Check("telegram", True, "opcional, não configurado", "telegram")
    try:
        system = "Windows" if is_windows(paths) else platform.system()
        state = manager_for(system, paths, runner, compat.current_uid()).state(BOT_LABEL)
    except NotSupportedHere:
        return Check("telegram", False, "o Telegram ainda não roda neste sistema", "telegram")
    ok = state == JobState.RUNNING
    return Check("telegram", ok, "Telegram conectado" if ok else "o Telegram está configurado mas parado", "telegram", {"job": state.value})


def _profile_complete(profile: Path) -> bool:
    try:
        data = json.loads(profile.read_text())
    except (OSError, ValueError):
        return False
    persona = data.get("persona") if isinstance(data, dict) else None
    agent = data.get("agent") if isinstance(data, dict) else None
    return (
        isinstance(persona, dict) and isinstance(agent, dict)
        and all(isinstance(persona.get(key), str) and persona[key] for key in ("name", "language", "user"))
        and isinstance(agent.get("cwd"), str)
    )


def _check_profile(paths: WispPaths, **_) -> Check:
    profile = Path(str(paths.config / "profile.json"))
    if profile.is_symlink():
        return Check("profile", True, "perfil gerenciado fora do Wisp", "profile")
    if not profile.exists():
        return Check("profile", False, "o perfil ainda não foi criado", "profile")
    ok = _profile_complete(profile)
    return Check("profile", ok, "perfil pronto" if ok else "o perfil ainda não está completo", "profile")


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


_OPTIONAL_CHECKS = {
    "codex": _check_codex,
    "codex_login": _check_codex_login,
}


_WINDOWS_CHECKS = {
    "os": _check_os,
    "git": _check_git,
    "claude": _check_claude,
    "claude_login": _check_claude_login,
    "brain": _check_brain,
    "harness": _check_harness,
    "telegram": _check_telegram,
    "profile": _check_profile,
}


def run_doctor(runner: Runner, paths: WispPaths, cfg: WispConfig, only: set[str] | None = None) -> list[Check]:
    available = {**(_WINDOWS_CHECKS if is_windows(paths) else _CHECKS), **(_OPTIONAL_CHECKS if only else {})}
    return [check(runner=runner, paths=paths, cfg=cfg) for id, check in available.items() if only is None or id in only]
