typeset -g _wisp_nonce=${WISP_MARK_NONCE-}; unset WISP_MARK_NONCE
# Wisp shell integration (zsh). The line above runs first: the marks' nonce moves into an unexported variable, so no child sees it.
# Wisp points ZDOTDIR here for the shell it starts; nothing of yours is changed.
# Each file here hands your own ZDOTDIR back while your matching file runs, then takes it again, so zsh keeps
# reading these. The last file puts everything back, and children see your original ZDOTDIR (or none).
if [[ -n ${WISP_ORIG_ZDOTDIR+x} ]]; then export ZDOTDIR=$WISP_ORIG_ZDOTDIR; else unset ZDOTDIR; fi
if [[ -r ${ZDOTDIR:-$HOME}/.zshenv ]]; then builtin source ${ZDOTDIR:-$HOME}/.zshenv; fi
if [[ -n ${ZDOTDIR+x} ]]; then typeset -g _wisp_user_zd_set=1 _wisp_user_zd=$ZDOTDIR; else typeset -g _wisp_user_zd_set= _wisp_user_zd=; fi
if [[ -o interactive && -n $WISP_ZDOTDIR ]]; then
  export ZDOTDIR=$WISP_ZDOTDIR
else
  unset WISP_ZDOTDIR WISP_ORIG_ZDOTDIR _wisp_user_zd_set _wisp_user_zd _wisp_nonce
fi
