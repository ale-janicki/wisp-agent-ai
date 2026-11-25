if [[ -n $_wisp_user_zd_set ]]; then export ZDOTDIR=$_wisp_user_zd; else unset ZDOTDIR; fi
if [[ $HISTFILE == $WISP_ZDOTDIR/* ]]; then HISTFILE=${ZDOTDIR:-$HOME}/${HISTFILE:t}; fi
if [[ -r ${ZDOTDIR:-$HOME}/.zshrc ]]; then builtin source ${ZDOTDIR:-$HOME}/.zshrc; fi
if [[ -n ${ZDOTDIR+x} ]]; then _wisp_user_zd_set=1; _wisp_user_zd=$ZDOTDIR; else _wisp_user_zd_set=; _wisp_user_zd=; fi

if [[ -o interactive && -z $_wisp_hooked && -n $_wisp_nonce ]]; then
  typeset -g _wisp_hooked=1 _wisp_running=0 _wisp_status=0

  _wisp_capture() { _wisp_status=$? }

  _wisp_precmd() {
    emulate -L zsh
    setopt extendedglob
    local LC_ALL=C url
    if (( _wisp_running )); then
      builtin printf '\e]6973;%s;D;%d\a' $_wisp_nonce $_wisp_status
      _wisp_running=0
    fi
    url="file://$HOST${PWD//(#m)[^a-zA-Z0-9\/._~-]/%${(l:2::0:)$(( [##16] #MATCH ))}}"
    builtin printf '\e]7;%s\a\e]6973;%s;cwd=%s\a\e]6973;%s;A\a' "$url" $_wisp_nonce "$url" $_wisp_nonce
    if [[ -z $_wisp_hist_sent && -n $HISTFILE ]]; then
      typeset -g _wisp_hist_sent=1
      local hist=$(builtin printf %s $HISTFILE | command base64 2>/dev/null)
      builtin printf '\e]6973;%s;hist=%s\a' $_wisp_nonce ${hist//[$'\n\r ']/}
    fi
    local bmark=$'%{\e]6973;'$_wisp_nonce$';B\a%}'
    PS1=${PS1//"$bmark"/}
    PS1+=$bmark
  }

  _wisp_preexec() {
    emulate -L zsh
    _wisp_running=1
    local text=${1[1,4096]} encoded
    encoded=$(builtin printf %s "$text" | command base64 2>/dev/null)
    encoded=${encoded//[$'\n\r ']/}
    builtin printf '\e]6973;%s;cmd=%s\a\e]6973;%s;C\a' $_wisp_nonce "$encoded" $_wisp_nonce
  }

  precmd_functions=(_wisp_capture $precmd_functions _wisp_precmd)
  preexec_functions+=(_wisp_preexec)
fi

if [[ -o login ]]; then
  export ZDOTDIR=$WISP_ZDOTDIR
else
  if [[ -n $_wisp_user_zd_set ]]; then export ZDOTDIR=$_wisp_user_zd; else unset ZDOTDIR; fi
  unset WISP_ZDOTDIR WISP_ORIG_ZDOTDIR _wisp_user_zd_set _wisp_user_zd
fi
