import filecmp
import json
import os
import shutil
import tempfile
import unicodedata
from dataclasses import replace
from pathlib import Path

from wisp.config import WispConfig, save_config
from wisp.fsops import atomic_write, ensure_dir
from wisp.paths import WispPaths
from wisp.report import Detail, StepReport
from wisp.setup.harness import update_persona_block
from wisp.setup.profile_writer import render_persona

AVATAR_MAX_BYTES = 5 * 1024 * 1024
FORBIDDEN_IN_NAMES = ("<!--", "-->", "{{", "}}")


DEFAULT_NAME = "Wisp"


def _existing_name(profile: Path) -> str | None:
    try:
        persona = json.loads(profile.read_text()).get("persona")
    except (OSError, ValueError, AttributeError):
        return None
    name = persona.get("name") if isinstance(persona, dict) else None
    return name if isinstance(name, str) and name.strip() else None


def _failed(summary: str) -> StepReport:
    return StepReport("profile", "failed", summary)


def _bad_name(value: str, what: str) -> str | None:
    if any(unicodedata.category(ch) in ("Cc", "Cf", "Zl", "Zp") for ch in value) or any(token in value for token in FORBIDDEN_IN_NAMES):
        return f"{what} não pode ter quebras de linha, caracteres de controle, <!--, --> nem chaves duplas"
    return None


def _avatar_extension(head: bytes) -> str | None:
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if head.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    return None


def _inspect_avatar(avatar: Path) -> str:
    """Extension decided by the file's own bytes; raises ValueError with one sentence."""
    try:
        if not avatar.is_file():
            raise ValueError("não achei a imagem escolhida")
        if avatar.stat().st_size > AVATAR_MAX_BYTES:
            raise ValueError("a imagem passa de 5 MB; escolha uma menor")
        with avatar.open("rb") as f:
            ext = _avatar_extension(f.read(12))
    except OSError:
        raise ValueError("não consegui ler a imagem escolhida") from None
    if ext is None:
        raise ValueError("a imagem precisa ser png, jpg, webp ou gif")
    return ext


def _stage_avatar(avatar: Path, config: Path) -> Path:
    """Streams the image into a hidden temp file next to its final place, capped at 5 MB."""
    ensure_dir(config)
    fd, tmp = tempfile.mkstemp(dir=config, prefix=".avatar.")
    try:
        with os.fdopen(fd, "wb") as out, avatar.open("rb") as src:
            shutil.copyfileobj(_Capped(src), out)
        os.chmod(tmp, 0o644)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return Path(tmp)


class _Capped:
    def __init__(self, src):
        self.src, self.left = src, AVATAR_MAX_BYTES

    def read(self, n: int = -1) -> bytes:
        chunk = self.src.read(min(n, self.left + 1) if n > 0 else self.left + 1)
        self.left -= len(chunk)
        if self.left < 0:
            raise ValueError("a imagem passa de 5 MB; escolha uma menor")
        return chunk


def setup_profile(
    paths: WispPaths, cfg: WispConfig, *, name: str | None, user_name: str | None, language: str, avatar: Path | None, dry_run: bool
) -> StepReport:
    if name is None:
        name = _existing_name(paths.config / "profile.json") or cfg.persona or DEFAULT_NAME
    name, language = name.strip(), language.strip()
    user = (user_name or cfg.user_name or "").strip()
    if not name:
        return _failed("o nome do seu Wisp não pode ficar vazio")
    if not user:
        return _failed("falta o seu nome")
    if not language:
        return _failed("falta o idioma")
    for value, what in ((name, "o nome do seu Wisp"), (user, "o seu nome")):
        if problem := _bad_name(value, what):
            return _failed(problem)
    profile_path = paths.config / "profile.json"
    target = None
    try:
        if avatar is not None:
            target = paths.config / f"avatar.{_inspect_avatar(avatar)}"
            if target.is_symlink():
                return _failed("o arquivo do avatar é um link; o Wisp não escreve através dele")
        text = render_persona(
            profile_path, name=name, user_name=user, language=language, avatar=str(target) if target else None, brain=cfg.brain
        )
    except ValueError as e:
        return _failed(str(e))
    except OSError:
        return _failed("o perfil atual não pôde ser lido")

    config_path = paths.config / "wisp.json"
    new_values = (name, user, language)
    cfg_changed = new_values != (cfg.persona, cfg.user_name, cfg.language) or not config_path.exists()
    changed = cfg_changed or not profile_path.exists() or profile_path.read_text() != text
    avatar_changed = target is not None and (not target.exists() or not filecmp.cmp(avatar, target, shallow=False))
    if dry_run:
        block_kind, _, _ = update_persona_block(paths, replace(cfg, persona=name, user_name=user, language=language), dry_run=True)
        return StepReport("profile", "done" if changed or avatar_changed or block_kind == "updated" else "skipped",
                          "dry run: nada foi escrito")

    staged = None
    try:
        if avatar_changed:
            staged = _stage_avatar(avatar, paths.config)
        if not profile_path.exists() or profile_path.read_text() != text:
            atomic_write(profile_path, text, mode=0o600)
        if staged:
            os.replace(staged, target)
            staged = None
        if target:
            for old in paths.config.glob("avatar.*"):
                if old != target and not old.is_symlink():
                    old.unlink()
    except ValueError as e:
        return _failed(str(e))
    except OSError:
        return _failed("não consegui salvar o perfil no disco")
    finally:
        if staged:
            staged.unlink(missing_ok=True)
    cfg.persona, cfg.user_name, cfg.language = name, user, language
    save_config(cfg, config_path)

    data: dict[str, str] = {}
    block_kind, reason, agente_problem = update_persona_block(paths, cfg, dry_run=False)
    if block_kind in ("conflict", "failed"):
        data["warning"] = f"As instruções do agente ainda têm o nome antigo: {reason}."
    changed = changed or avatar_changed or block_kind == "updated"
    details = [Detail("agente", 0, agente_problem)] if agente_problem else []
    if changed or "warning" in data:
        return StepReport("profile", "done", "perfil salvo", details, data)
    return StepReport("profile", "skipped", "o perfil já estava assim", details, data)

