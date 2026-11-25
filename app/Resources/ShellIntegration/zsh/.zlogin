# Wisp shell integration (zsh): your .zlogin runs as it would without Wisp, then everything is put back.
if [[ -n $_wisp_user_zd_set ]]; then export ZDOTDIR=$_wisp_user_zd; else unset ZDOTDIR; fi
if [[ -r ${ZDOTDIR:-$HOME}/.zlogin ]]; then builtin source ${ZDOTDIR:-$HOME}/.zlogin; fi
if [[ -n ${ZDOTDIR+x} ]]; then export ZDOTDIR; fi
unset WISP_ZDOTDIR WISP_ORIG_ZDOTDIR _wisp_user_zd_set _wisp_user_zd
