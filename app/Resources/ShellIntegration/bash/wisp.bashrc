__wisp_nonce=$WISP_MARK_NONCE; unset WISP_MARK_NONCE
if [ -r /etc/profile ]; then . /etc/profile; fi
if [ -r "$HOME/.bash_profile" ]; then
  . "$HOME/.bash_profile"
elif [ -r "$HOME/.bash_login" ]; then
  . "$HOME/.bash_login"
elif [ -r "$HOME/.profile" ]; then
  . "$HOME/.profile"
fi

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

__wisp_cwd() {
  local url
  url="file://${HOSTNAME:-localhost}$(__wisp_encode "$PWD")"
  builtin printf '\e]7;%s\a\e]6973;%s;cwd=%s\a' "$url" "$__wisp_nonce" "$url"
}

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

if [ -n "$__wisp_nonce" ] && [ -z "$(trap -p DEBUG)" ] && [ -z "${__wisp_hooked-}" ]; then
  __wisp_hooked=1
  __wisp_ready=0
  __wisp_running=0
  __wisp_status=0
  __wisp_hist=

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

  __wisp_capture() {
    __wisp_status=$?
    __wisp_ready=0
    return $__wisp_status
  }

  __wisp_emit() {
    if [ "$__wisp_running" = 1 ]; then
      builtin printf '\e]6973;%s;D;%s\a' "$__wisp_nonce" "$__wisp_status"
      __wisp_running=0
    fi
    __wisp_cwd
    if [ -z "${__wisp_hist_sent-}" ] && [ -n "${HISTFILE-}" ]; then
      __wisp_hist_sent=1
      builtin printf '\e]6973;%s;hist=%s\a' "$__wisp_nonce" "$(builtin printf '%s' "$HISTFILE" | command base64 2>/dev/null | command tr -d '\n\r ')"
    fi
    builtin printf '\e]6973;%s;A\a' "$__wisp_nonce"
    local bmark='\[\e]6973;'$__wisp_nonce';B\a\]'
    PS1=${PS1//"$bmark"/}
    PS1+=$bmark
    __wisp_last_entry
    __wisp_hist=$__wisp_entry_number
    __wisp_ready=1
  }

  __wisp_debug() {
    [ -n "${COMP_LINE-}" ] && return 0
    case $BASH_COMMAND in __wisp_*) return 0 ;; esac
    [ "$__wisp_ready" = 1 ] || return 0
    __wisp_ready=0
    __wisp_running=1
    local text=$BASH_COMMAND encoded
    __wisp_last_entry
    if [ -n "$__wisp_entry_number" ] && [ "$__wisp_entry_number" != "$__wisp_hist" ]; then text=$__wisp_entry_text; fi
    encoded=$(builtin printf '%s' "${text:0:4096}" | command base64 2>/dev/null | command tr -d '\n\r ')
    builtin printf '\e]6973;%s;cmd=%s\a\e]6973;%s;C\a' "$__wisp_nonce" "$encoded" "$__wisp_nonce"
  }

  __wisp_wrap_prompt_command __wisp_capture __wisp_emit
  trap '__wisp_debug' DEBUG
elif [ -n "$__wisp_nonce" ] && [ -z "${__wisp_hooked-}" ]; then
  __wisp_hooked=1
  builtin printf '\e]6973;%s;declined\a' "$__wisp_nonce"
  __wisp_wrap_prompt_command "" __wisp_cwd
else
  unset __wisp_nonce
  unset -f __wisp_encode __wisp_cwd __wisp_wrap_prompt_command
fi
