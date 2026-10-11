# Sourced before completion.bash so ble.sh can integrate Starship's hooks.
[[ $- == *i* ]] || return 0
command -v starship >/dev/null 2>&1 || return 0
[[ -r ${XDG_CONFIG_HOME:-$HOME/.config}/tmux/shell/starship.toml ]] || return 0

export STARSHIP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/shell/starship.toml"
eval "$(starship init bash)"
