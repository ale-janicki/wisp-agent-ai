set -g __wisp_nonce $WISP_MARK_NONCE
set -e WISP_MARK_NONCE
# Wisp shell integration (fish). The two lines above run first: the marks' nonce moves into an unexported variable, so no child
# sees it. Wisp puts its directory first in XDG_DATA_DIRS, so fish loads this file as a vendor configuration; nothing of yours is
# changed. The variable is put back right here. Every mark is Wisp's own OSC with the nonce (`OSC 6973;<nonce>;…`): output that
# imitates one makes no block.
if set -q WISP_XDG_DATA_DIRS_ORIG
    if test -n "$WISP_XDG_DATA_DIRS_ORIG"
        set -gx XDG_DATA_DIRS $WISP_XDG_DATA_DIRS_ORIG
    else
        set -e XDG_DATA_DIRS
    end
    set -e WISP_XDG_DATA_DIRS_ORIG
end

status is-interactive; or exit
test -n "$__wisp_nonce"; or exit

function __wisp_prompt --on-event fish_prompt
    set -l url "file://"(hostname)(string escape --style=url -- $PWD)
    # Plain OSC 7 too, for the terminal's own use (links are opened relative to it); Wisp takes the folder only from `cwd=`.
    printf '\e]7;%s\a\e]6973;%s;cwd=%s\a\e]6973;%s;A\a' "$url" "$__wisp_nonce" "$url" "$__wisp_nonce"
end

# The whole command line, newlines kept: it goes to base64 as one argument, never split into a list.
function __wisp_preexec --on-event fish_preexec
    set -l encoded (printf '%s' "$argv[1]" | command head -c 4096 | command base64 | string join '')
    printf '\e]6973;%s;cmd=%s\a\e]6973;%s;C\a' "$__wisp_nonce" "$encoded" "$__wisp_nonce"
end

function __wisp_postexec --on-event fish_postexec
    printf '\e]6973;%s;D;%s\a' "$__wisp_nonce" $status
end
