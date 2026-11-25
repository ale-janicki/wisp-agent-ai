# Wisp shell integration (zsh): your .zprofile runs as it would without Wisp.
if [[ -n $_wisp_user_zd_set ]]; then export ZDOTDIR=$_wisp_user_zd; else unset ZDOTDIR; fi
if [[ -r ${ZDOTDIR:-$HOME}/.zprofile ]]; then builtin source ${ZDOTDIR:-$HOME}/.zprofile; fi
if [[ -n ${ZDOTDIR+x} ]]; then _wisp_user_zd_set=1; _wisp_user_zd=$ZDOTDIR; else _wisp_user_zd_set=; _wisp_user_zd=; fi
export ZDOTDIR=$WISP_ZDOTDIR
