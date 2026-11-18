import stat

from wisp.config import WispConfig, save_config


def _mode(p):
    return stat.S_IMODE(p.stat().st_mode)


def test_config_is_private(fake_home):
    target = fake_home / ".config/wisp/wisp.json"
    save_config(WispConfig(), target)
    assert _mode(target) == 0o600
