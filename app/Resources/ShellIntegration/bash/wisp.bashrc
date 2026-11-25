__wisp_nonce=$WISP_MARK_NONCE; unset WISP_MARK_NONCE
# Wisp shell integration (bash). The line above runs first: the marks' nonce moves into an unexported variable, so no child sees it.
# Wisp starts bash with --init-file pointing here, because a login shell ignores that option. So this file does what a login shell
# does (your profile, never your .bashrc unless your profile loads it), then adds the hooks. Nothing of yours is changed. Works on
# bash 3.2 (macOS /bin/bash). Every mark is Wisp's own OSC with the nonce (`OSC 6973;<nonce>;…`): output that imitates one makes no block.
if [ -r /etc/profile ]; then . /etc/profile; fi
if [ -r "$HOME/.bash_profile" ]; then
  . "$HOME/.bash_profile"
elif [ -r "$HOME/.bash_login" ]; then
  . "$HOME/.bash_login"
elif [ -r "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi

# Percent-encodes a path byte by byte. bash 3.2 gives a byte above 127 as a negative number, so it is masked to one byte.
__wisp_encode() {
  local LC_ALL=C text=$1 out= char byte hex i
  for ((i = 0; i < ${#text}; i++)); do
    char=${text:i:1}
    case $char in
      [a-zA-Z0-9/._~-]) out+=$char ;;
      *)
        printf -v byte '%d' "'$char"
        printf -v hex '%%%02X' $((byte & 255))
        out+=$hex
        ;;
    esac
  done
  printf '%s' "$out"
}

# The folder, before each prompt. Plain OSC 7 too, for the terminal's own use (links are opened relative to it); Wisp takes the
# folder only from `cwd=`.
__wisp_cwd() {
  local url
  url="file://${HOSTNAME:-localhost}$(__wisp_encode "$PWD")"
  builtin printf '\e]7;%s\a\e]6973;%s;cwd=%s\a' "$url" "$__wisp_nonce" "$url"
}

# Puts $1 first and $2 last in PROMPT_COMMAND (string or array). An exported PROMPT_COMMAND stops being exported: the hooks' value
# would reach a nested bash, which has no such functions.
__wisp_wrap_prompt_command() {
  local flags
  flags=$(declare -p PROMPT_COMMAND 2>/dev/null)
  flags=${flags#declare -}
  flags=${flags%% *}
  case $flags in *x*) export -n PROMPT_COMMAND ;; esac
  case $flags in
    *a*) PROMPT_COMMAND=($1 "${PROMPT_COMMAND[@]}" $2) ;;
    *) PROMPT_COMMAND="${1:+$1$'\n'}${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}$2" ;;
  esac
}

# Another DEBUG trap is left alone: the shell says so (`declined`), makes no blocks, and still reports its folder.
if [ -n "$__wisp_nonce" ] && [ -z "$(trap -p DEBUG)" ] && [ -z "$__wisp_hooked" ]; then
  __wisp_hooked=1
  __wisp_ready=0
  __wisp_running=0
  __wisp_status=0
  __wisp_hist=

  # The newest history entry: its number and its text (the whole line typed, pipes and lists included).
  __wisp_last_entry() {
    local line pattern='^[[:space:]]*([0-9]+)\*?[[:space:]]+(.*)$'
    line=$(HISTTIMEFORMAT= builtin history 1)
    __wisp_entry_number=
    __wisp_entry_text=
    if [[ $line =~ $pattern ]]; then
      __wisp_entry_number=${BASH_REMATCH[1]}
      __wisp_entry_text=${BASH_REMATCH[2]}
    fi
  }

  # First in PROMPT_COMMAND: the exit status of the command, kept and handed on, so your PROMPT_COMMAND still sees it in $?.
  # From here until the prompt is drawn nothing counts as a command typed.
  __wisp_capture() {
    __wisp_status=$?
    __wisp_ready=0
    return $__wisp_status
  }

  # Last in PROMPT_COMMAND: the marks, with the prompt about to be drawn.
  __wisp_emit() {
    if [ "$__wisp_running" = 1 ]; then
      builtin printf '\e]6973;%s;D;%s\a' "$__wisp_nonce" "$__wisp_status"
      __wisp_running=0
    fi
    __wisp_cwd
    builtin printf '\e]6973;%s;A\a' "$__wisp_nonce"
    __wisp_last_entry
    __wisp_hist=$__wisp_entry_number
    __wisp_ready=1
  }

  # Before each simple command. Only the first one after a prompt counts, once (`a | b; c` is one command), and never one of
  # PROMPT_COMMAND's (an empty Enter or Ctrl-C at the prompt runs PROMPT_COMMAND only) or a completion function.
  __wisp_debug() {
    [ -n "${COMP_LINE-}" ] && return 0
    case $BASH_COMMAND in __wisp_*) return 0 ;; esac
    [ "$__wisp_ready" = 1 ] || return 0
    __wisp_ready=0
    __wisp_running=1
    local text=$BASH_COMMAND encoded
    # The line typed is in history by now. A line history did not keep (ignorespace, ignoredups) leaves the number as it was:
    # then only the simple command is known.
    __wisp_last_entry
    if [ -n "$__wisp_entry_number" ] && [ "$__wisp_entry_number" != "$__wisp_hist" ]; then text=$__wisp_entry_text; fi
    encoded=$(builtin printf '%s' "${text:0:4096}" | command base64 2>/dev/null | command tr -d '\n\r ')
    builtin printf '\e]6973;%s;cmd=%s\a\e]6973;%s;C\a' "$__wisp_nonce" "$encoded" "$__wisp_nonce"
  }

  __wisp_wrap_prompt_command __wisp_capture __wisp_emit
  trap '__wisp_debug' DEBUG
elif [ -n "$__wisp_nonce" ] && [ -z "$__wisp_hooked" ]; then
  __wisp_hooked=1
  builtin printf '\e]6973;%s;declined\a' "$__wisp_nonce"
  __wisp_wrap_prompt_command "" __wisp_cwd
else
  unset __wisp_nonce
  unset -f __wisp_encode __wisp_cwd __wisp_wrap_prompt_command
fi
