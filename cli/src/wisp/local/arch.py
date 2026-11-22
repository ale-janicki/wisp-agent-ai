import platform

NEEDS_APPLE_SILICON = (
    "o MLX local precisa de um Mac com Apple silicon e este não tem; aponte para um servidor compatível com OpenAI "
    "(wisp local backend openai --url ENDEREÇO --model MODELO) ou use o Claude ou o Codex, que rodam na assinatura"
)


def chip_is_apple_silicon(chip: str) -> bool:
    return chip.strip().lower().startswith("apple")


def host_is_apple_silicon() -> bool:
    return platform.system() == "Darwin" and platform.machine() == "arm64"
