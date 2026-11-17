import json
import re
from pathlib import Path

from wisp.config import WispConfig, save_config
from wisp.doctor import locate_claude
from wisp.fsops import ensure_dir
from wisp.paths import WispPaths
from wisp.report import Detail, StepReport
from wisp.runner import Runner

CLAUDE_INSTALL_SCRIPT = "curl -fsSL https://claude.ai/install.sh | bash"
BREW_RELEASE_API = "https://api.github.com/repos/Homebrew/brew/releases/latest"
BREW_DOWNLOAD_PREFIX = "https://github.com/Homebrew/brew/releases/download/"
BREW_BINARIES = ("/opt/homebrew/bin/brew", "/usr/local/bin/brew")
BREW_LEAF = re.compile(r"^\s*1\.\s+Developer ID Installer: .+ \(927JGANW46\)\s*$", re.M)
BREW_STATUS = re.compile(r"^\s*Status:\s+signed by a developer certificate issued by Apple for distribution( \(Notarized\))?\s*$", re.M)
CLT_REQUESTED = "install requested"
CLT_SUMMARY = "Clique em Instalar na janela da Apple; o Wisp continua sozinho quando terminar"
BREW_SUMMARY = "O instalador do Homebrew vai pedir a senha do seu Mac"


def _brew_present(runner: Runner) -> bool:
    return any(runner.run([binary, "--version"], timeout=10).exit == 0 for binary in BREW_BINARIES)


def _record(runner: Runner, details: list[Detail], argv: list[str], timeout: float):
    result = runner.run(argv, timeout=timeout)
    details.append(Detail.capture(" ".join(argv), result.exit, result.stdout, result.stderr))
    return result


def _install_claude(runner: Runner, paths: WispPaths, cfg: WispConfig, details: list[Detail]) -> Path | None:
    argv = ["/bin/bash", "-c", CLAUDE_INSTALL_SCRIPT]
    if _record(runner, details, argv, 600).exit != 0:
        return None
    return locate_claude(paths, cfg, runner)


def _homebrew_pkg(runner: Runner, paths: WispPaths, details: list[Detail]) -> tuple[Path | None, str]:
    release = _record(runner, details, ["curl", "-fsSL", BREW_RELEASE_API], 30)
    try:
        url = next(
            (
                a["browser_download_url"]
                for a in json.loads(release.stdout)["assets"]
                if a["name"].startswith("Homebrew") and a["name"].endswith(".pkg") and a["browser_download_url"].startswith(BREW_DOWNLOAD_PREFIX)
            ),
            None,
        )
    except (ValueError, KeyError, TypeError, AttributeError):
        return None, "não consegui ler a resposta do Homebrew"
    if url is None:
        return None, "não achei o instalador do Homebrew"
    downloads = paths.state / "downloads"
    ensure_dir(downloads)
    pkg = downloads / url.rsplit("/", 1)[-1]
    if _record(runner, details, ["curl", "-fsSL", "-o", str(pkg), url], 600).exit != 0:
        return None, "não consegui baixar o instalador do Homebrew"
    check = _record(runner, details, ["pkgutil", "--check-signature", str(pkg)], 60)
    output = check.stdout + check.stderr
    if check.exit != 0 or not BREW_LEAF.search(output) or not BREW_STATUS.search(output):
        return None, "o instalador do Homebrew não tem a assinatura esperada; não foi aberto"
    return pkg, ""


def setup_system(runner: Runner, paths: WispPaths, cfg: WispConfig, *, with_homebrew: bool, dry_run: bool) -> StepReport:
    details: list[Detail] = []
    clt_ok = runner.run(["xcode-select", "-p"], timeout=10).exit == 0
    claude = locate_claude(paths, cfg, runner) if clt_ok or dry_run else None
    brew_missing = with_homebrew and not _brew_present(runner)
    data: dict[str, str] = {"claude": str(claude)} if claude else {}

    if dry_run:
        missing = [name for name, absent in (("clt", not clt_ok), ("claude", claude is None), ("homebrew", brew_missing)) if absent]
        return StepReport("system", "done", "dry run: nada foi instalado", data={**data, "missing": ",".join(missing)})
    if not clt_ok:
        opened = _record(runner, details, ["xcode-select", "--install"], 30)
        if opened.exit != 0 and CLT_REQUESTED not in (opened.stdout + opened.stderr).lower():
            return StepReport("system", "failed", "não consegui abrir o instalador da Apple", details)
        return StepReport("system", "needs_user", CLT_SUMMARY, details)

    changed = False
    if claude is None:
        claude = _install_claude(runner, paths, cfg, details)
        if claude is None:
            return StepReport("system", "failed", "não consegui instalar o Claude Code", details)
        changed = True
    version = _record(runner, details, [str(claude), "--version"], 10).stdout.strip()
    data = {"claude": str(claude), "claude_version": version}
    if cfg.claude_bin != str(claude):
        cfg.claude_bin = str(claude)
        save_config(cfg)

    if brew_missing:
        pkg, problem = _homebrew_pkg(runner, paths, details)
        if pkg is None:
            return StepReport("system", "failed", problem, details, data)
        _record(runner, details, ["open", str(pkg)], 30)
        return StepReport("system", "needs_user", BREW_SUMMARY, details, data)
    if changed:
        return StepReport("system", "done", "Claude Code instalado", details, data)
    return StepReport("system", "skipped", "tudo pronto", details, data)
