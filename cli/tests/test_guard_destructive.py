import io
import json
from pathlib import Path

import pytest

from wisp.cli import main
from wisp.config import WispConfig
from wisp.guard_destructive import hook_guard_destructive
from wisp.paths import WispPaths

HOME = "/Users/rita"
BRAIN = f"{HOME}/Wisp/brain"
WORK = f"{HOME}/code/app"
PATHS = WispPaths(Path(HOME), Path(HOME) / ".config/wisp", Path("/d"), Path("/s"), Path("/b"), None)


def _decide(command, cwd=WORK, tool="Bash"):
    payload = {"tool_name": tool, "tool_input": {"command": command}, "cwd": cwd}
    return hook_guard_destructive(payload, PATHS, WispConfig(brain=BRAIN))


BLOCKED = [
    "rm -rf /",
    "rm -rf ~",
    "rm -rf $HOME",
    "rm -rf ${HOME}/",
    "rm -fr ~/Documents",
    "rm -R ~/Desktop",
    "rm --recursive --force ~/Pictures",
    "sudo rm -rf /Applications",
    "sudo -u root rm -rf /System",
    "rm -rf /Users",
    "rm -rf /Volumes/Backup",
    "rm -rf /Volumes/*",
    "rm -rf ~/Documents/*",
    "rm -rf ~/Downloads/.*",
    "rm -rf ~/*",
    "rm -rf -- ~/Movies",
    "rm -rf ~/Library",
    "rm -rf '~/Library/Mobile Documents'",
    "rm -rf ~/Wisp",
    f"rm -rf {BRAIN}",
    f"rm -rf {BRAIN}/*",
    "cd ~/Music && rm -rf *",
    "ls && rm -rf ~/Documents",
    "bash -c 'rm -rf ~/Documents'",
    "echo hi; rm -rf ~",
    "rm -rf ~/.Trash",
    "rm -rf ~/.Trash/*",
    "osascript -e 'tell application \"Finder\" to empty the trash'",
    "diskutil eraseDisk JHFS+ X /dev/disk99",
    "diskutil partitionDisk disk2 GPT JHFS+ X 100%",
    "diskutil zeroDisk disk2",
    "diskutil secureErase 0 disk2",
    "diskutil apfs deleteContainer disk3",
    "mkfs.ext4 /dev/sdb1",
    "newfs_apfs /dev/disk4",
    "dd if=/dev/zero of=/dev/disk2 bs=1m",
    "cat image.iso > /dev/rdisk2",
    "asr restore --source a.dmg --target /Volumes/X",
    "tmutil delete /Volumes/Backup/x",
    "tmutil deletelocalsnapshots 2024-01-01",
    "csrutil disable",
    "nvram -c",
    "sudo launchctl bootout system/com.apple.x",
    "sudo shutdown -h now",
    "reboot",
    "chmod -R 777 ~",
    "chown -R rita /Applications",
    "find ~/Documents -name '*.tmp' -delete",
    "find ~ -exec rm {} +",
    "rsync -a --delete /tmp/empty/ ~/Documents/",
    "rsync -a --delete-after src/ ~/",
    f"cd {BRAIN} && git reset --hard",
    f"git -C {BRAIN} clean -fdx",
    "cd ~/Wisp && git clean -fd",
    "rm -rf ~/documents",
    "rm -rf ~/DOCUMENTS",
    f"rm -rf {HOME}/documents",
    "rm -rf ~/desktop",
    "rm -rf ~/library",
    "rm -rf ~/.trash",
    "rm -rf ~/DOCUMENTS/*",
    "bash -lc 'rm -rf ~/Documents'",
    "zsh -ic 'rm -rf ~/Documents'",
    "sh -ec 'rm -rf ~'",
    "sudo bash -xc \"rm -rf ~/Desktop\"",
    "{ rm -rf ~/Documents; }",
    "(rm -rf ~/Documents)",
    "if true; then rm -rf ~/Documents; fi",
    "if rm -rf ~/Documents; then echo x; fi",
    "for f in a; do rm -rf ~/Documents; done",
    "while true; do rm -rf ~/Documents; done",
    "! rm -rf ~/Documents",
    "time rm -rf ~/Documents",
    "command rm -rf ~",
    "builtin exec rm -rf ~",
    "nohup rm -rf ~/Documents",
    "\\rm -rf ~",
    "/bin/rm -rf ~",
    "/usr/bin/rm -rf ~/Documents",
    "rm -rf ~/{Documents,Desktop}",
    "rm -rf ~/{tmp,Documents}",
    "rm -rf {~/Documents,/tmp/x}",
    "echo ~/Documents | xargs rm -rf",
    "find ~/Documents -maxdepth 1 | xargs rm -rf",
    "ls ~/Documents | xargs -I {} rm -rf {}",
    "xargs rm -rf <<< ~/Documents",
    "xargs rm -rf <<EOF\n~/Documents\nEOF",
    "cd ~/Documents && rm -rf ./*",
    "cd ~/Documents && rm -rf *",
    "cd ~/Documents; ls | xargs rm -rf",
    "unlink ~/Documents",
    "rmdir ~/Desktop",
    "rm -rf $(echo ~/Documents)",
    "rm -rf `echo ~/Documents`",
    "rm -rf $(rm -rf ~/Music)",
    "X=~/Documents; rm -rf $X",
    "X=~/Documents; rm -rf ${X}",
    "export X=~/Documents && rm -rf \"$X\"",
    "A=~; B=$A/Documents; rm -rf $B",
]

ALLOWED = [
    "rm file.txt",
    "rm -rf ./build",
    "rm -rf build node_modules",
    "rm -rf /tmp/x",
    "rm -rf /tmp/*",
    "rm -rf ~/Downloads/old-folder",
    "rm -rf ~/Documents/proj/dist",
    "rm -rf ~/Downloads/old-*",
    "rm -f ~/.Trash/one-file.txt",
    "rm ~/Documents",
    "trash ~/Downloads/old-folder",
    "mv x ~/.Trash/",
    "diskutil list",
    "diskutil info disk1",
    "dd if=a of=b bs=1m",
    "dd if=/dev/zero of=/dev/null count=1",
    "csrutil status",
    "tmutil listbackups",
    "launchctl bootout gui/501/ai.wisp.bot",
    "chmod -R 755 ./dist",
    "chmod 644 ~/Documents",
    "find . -name '*.pyc' -delete",
    "find ~/Documents -name '*.tmp'",
    "rsync -a src/ ~/Documents/",
    "rsync -a --delete src/ ~/Documents/proj/",
    "git status",
    "git reset --hard HEAD~1",
    "git clean -fdx",
    "echo 'rm -rf ~'",
    "ls ~/Documents && cat notes.txt | grep x",
    "cd ~/Documents/proj && rm -rf *",
    "osascript -e 'display dialog \"hi\"'",
    "unterminated 'quote rm",
    "rm ~/Documents/x.txt",
    "rm -rf ~/Documents/proj",
    'rm -rf "~/Downloads/some folder"',
    "trash ~/Documents/x",
    "rm -rf ~/documents/proj",
    "bash -lc 'ls ~/Documents'",
    "bash -lc 'rm -rf ./build'",
    "{ rm -rf ./build; }",
    "if true; then rm -rf /tmp/x; fi",
    "for f in a; do rm -rf /tmp/$f; done",
    "command rm -rf ./build",
    "rm -rf ~/Downloads/{a,b}",
    "ls ~/Documents | xargs echo",
    "find . -name '*.pyc' | xargs rm -f",
    "echo ~/Documents | xargs ls",
    "rmdir ./empty",
    "unlink ./x",
    "rm -rf $(ls /tmp/x)",
    "echo $(ls ~/Documents)",
    "X=/tmp/x; rm -rf $X",
    "X=~/Documents; echo $X",
    "X=~/Documents/proj; rm -rf $X",
]


@pytest.mark.parametrize("command", BLOCKED)
def test_blocks(command):
    reason = _decide(command)
    assert reason and reason.startswith("wisp-guard:") and "Trash" in reason, command


@pytest.mark.parametrize("command", ALLOWED)
def test_allows(command):
    assert _decide(command) is None, command


def test_git_destructive_is_only_blocked_in_the_brain_or_wisp_folder():
    assert _decide("git reset --hard", cwd=BRAIN)
    assert _decide("git reset --hard", cwd=f"{BRAIN}/notes")
    assert _decide("git clean -fd", cwd=f"{HOME}/Wisp")
    assert _decide("git reset --hard", cwd=WORK) is None
    assert _decide("git clean -fdx", cwd=WORK) is None


def test_relative_and_dot_targets_resolve_against_the_call_cwd():
    assert _decide("rm -rf .", cwd=HOME)
    assert _decide("rm -rf *", cwd=f"{HOME}/Documents")
    assert _decide("rm -rf ..", cwd=f"{HOME}/Documents")
    assert _decide("rm -rf .", cwd=WORK) is None
    assert _decide("rm -rf *", cwd=WORK) is None


def test_the_configured_wisp_folder_is_protected_not_a_fixed_one():
    cfg = WispConfig(brain=BRAIN, wisp_dir="~/Meu Wisp")
    def decide(command, cwd=WORK):
        return hook_guard_destructive({"tool_name": "Bash", "tool_input": {"command": command}, "cwd": cwd}, PATHS, cfg)
    assert decide("rm -rf ~/Meu\\ Wisp")
    assert decide("git clean -fd", cwd=f"{HOME}/Meu Wisp")
    assert decide("rm -rf ~/Wisp") is None
    assert decide("git clean -fd", cwd=f"{HOME}/Wisp") is None


def test_other_tools_and_bad_payloads_pass():
    assert _decide("rm -rf ~", tool="Read") is None
    assert hook_guard_destructive({"tool_name": "Bash", "tool_input": "x"}, PATHS, WispConfig()) is None
    assert hook_guard_destructive({}, PATHS, WispConfig()) is None


def test_cli_exits_2_on_block_and_0_otherwise(fake_home, monkeypatch, capsys):
    block = {"tool_name": "Bash", "tool_input": {"command": "rm -rf ~/Documents/*"}, "cwd": str(fake_home)}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(block)))
    assert main(["hook", "guard-destructive"]) == 2
    assert capsys.readouterr().err.startswith("wisp-guard:")
    ok = {"tool_name": "Bash", "tool_input": {"command": "ls"}, "cwd": str(fake_home)}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(ok)))
    assert main(["hook", "guard-destructive"]) == 0
    monkeypatch.setattr("sys.stdin", io.StringIO("not json"))
    assert main(["hook", "guard-destructive"]) == 2
