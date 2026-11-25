set -g __wisp_nonce $WISP_MARK_NONCE
set -e WISP_MARK_NONCE
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
    printf '\e]7;%s\a\e]6973;%s;cwd=%s\a\e]6973;%s;A\a' "$url" "$__wisp_nonce" "$url" "$__wisp_nonce"
    if not set -q __wisp_hist_sent; and test "$fish_history" != ""
        set -g __wisp_hist_sent 1
        set -l data "$HOME/.local/share"
        test -n "$XDG_DATA_HOME"; and set data "$XDG_DATA_HOME"
        set -l name fish
        test -n "$fish_history"; and set name "$fish_history"
        printf '\e]6973;%s;hist=%s\a' "$__wisp_nonce" (printf '%s' "$data/fish/$name"_history | command base64 | string join '')
    end
    __wisp_wrap_prompt
end

function __wisp_wrap_prompt
    functions -q fish_prompt; or return
    string match -q '*__wisp_prompt_end*' (functions fish_prompt | string collect); and return
    functions -e __wisp_orig_prompt
    functions -c fish_prompt __wisp_orig_prompt
    function fish_prompt --description 'prompt wrapped by Wisp'
        __wisp_orig_prompt
        __wisp_prompt_end
    end
end

function __wisp_prompt_end
    printf '\e]6973;%s;B\a' "$__wisp_nonce"
end

function __wisp_preexec --on-event fish_preexec
    set -l encoded (printf '%s' "$argv[1]" | command head -c 4096 | command base64 | string join '')
    printf '\e]6973;%s;cmd=%s\a\e]6973;%s;C\a' "$__wisp_nonce" "$encoded" "$__wisp_nonce"
end

function __wisp_postexec --on-event fish_postexec
    printf '\e]6973;%s;D;%s\a' "$__wisp_nonce" $status
end
