#!/usr/bin/env bash

# Install the optional terminal pieces used by Beck tmux.
# The script is deliberately idempotent: existing eza/synth-shell installs and
# existing shell customizations are preserved.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HOME_DIR="${HOME:?HOME must be set}"
BASHRC="${HOME_DIR}/.bashrc"
TMUX_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}/tmux"
TMUX_CONFIG="${TMUX_CONFIG_DIR}/tmux.conf"
SYNTH_DIR="${HOME_DIR}/.local/share/synth-shell"
OVERWRITE_CONFIG=0

info() { printf '[tmux-setup] %s\n' "$*"; }
warn() { printf '[tmux-setup] warning: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: setup.sh [--overwrite]

Options:
  --overwrite  replace the destination tmux.conf after making a timestamped backup
  -h, --help   show this help
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --overwrite) OVERWRITE_CONFIG=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; return 2 ;;
    esac
    shift
  done
}

install_tmux_config() {
  local source_config="${PROJECT_DIR}/tmux.conf"
  [[ -f "${source_config}" ]] || { warn "project config not found at ${source_config}"; return; }

  mkdir -p "${TMUX_CONFIG_DIR}"
  if [[ -e "${TMUX_CONFIG}" && "${source_config}" -ef "${TMUX_CONFIG}" ]]; then
    info "using project config in place: ${TMUX_CONFIG}"
    return
  fi
  if [[ -e "${TMUX_CONFIG}" && "${OVERWRITE_CONFIG}" -ne 1 ]]; then
    warn "existing ${TMUX_CONFIG} preserved (pass --overwrite to replace it)"
    return
  fi
  if [[ -e "${TMUX_CONFIG}" ]]; then
    local backup_path="${TMUX_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "${TMUX_CONFIG}" "${backup_path}"
    info "backed up existing config to ${backup_path}"
  fi
  cp -p "${source_config}" "${TMUX_CONFIG}"
  info "installed ${TMUX_CONFIG}"
}

install_eza() {
  if command -v eza >/dev/null 2>&1; then
    info "eza already installed: $(command -v eza)"
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    info 'installing eza with apt'
    if command -v sudo >/dev/null 2>&1; then
      sudo apt-get update
      sudo apt-get install -y eza
    else
      apt-get update
      apt-get install -y eza
    fi
  elif command -v dnf >/dev/null 2>&1; then
    info 'installing eza with dnf'
    sudo dnf install -y eza
  elif command -v pacman >/dev/null 2>&1; then
    info 'installing eza with pacman'
    sudo pacman -S --needed --noconfirm eza
  elif command -v brew >/dev/null 2>&1; then
    info 'installing eza with Homebrew'
    brew install eza
  else
    warn 'no supported package manager found for eza; install it manually'
  fi
}

install_synth_shell() {
  if [[ -f "${HOME_DIR}/.config/synth-shell/synth-shell-prompt.sh" ]]; then
    info 'synth-shell already configured in ~/.config/synth-shell'
    return
  fi

  if ! command -v git >/dev/null 2>&1; then
    warn 'git is required to install synth-shell'
    return
  fi

  mkdir -p "$(dirname -- "${SYNTH_DIR}")"
  if [[ ! -d "${SYNTH_DIR}/.git" ]]; then
    info "cloning synth-shell into ${SYNTH_DIR}"
    git clone --recursive https://github.com/andresgongora/synth-shell.git "${SYNTH_DIR}"
  else
    info 'updating existing synth-shell checkout'
    git -C "${SYNTH_DIR}" pull --ff-only
    git -C "${SYNTH_DIR}" submodule update --init --recursive
  fi

  if [[ -x "${SYNTH_DIR}/setup.sh" && -t 0 && -t 1 ]]; then
    info 'starting synth-shell interactive installer'
    (cd "${SYNTH_DIR}" && ./setup.sh)
  else
    warn 'synth-shell is downloaded; run its setup.sh interactively to select features'
  fi
}

wire_eza_aliases() {
  [[ -f "${BASHRC}" ]] || return
  command -v eza >/dev/null 2>&1 || return

  local marker='# >>> beck tmux eza integration >>>'
  if grep -Eq "^[[:space:]]*alias[[:space:]]+ls=['\"]eza[[:space:]]" "${BASHRC}" 2>/dev/null; then
    info 'eza aliases already configured in ~/.bashrc'
    return
  fi
  grep -Fqx "${marker}" "${BASHRC}" 2>/dev/null && {
    info 'eza aliases already present in ~/.bashrc'
    return
  }

  info 'adding guarded eza aliases to ~/.bashrc'
  cat >>"${BASHRC}" <<'EOF'

# >>> beck tmux eza integration >>>
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --icons=auto --git --group-directories-first'
  alias l='eza --icons=auto --git --group-directories-first'
  alias ll='eza -l --icons=auto --git --group-directories-first'
  alias la='eza -a --icons=auto --git --group-directories-first'
  alias lt='eza --tree --level=2 --icons=auto'
fi
# <<< beck tmux eza integration <<<
EOF
}

main() {
  parse_args "$@"
  install_tmux_config
  command -v tmux >/dev/null 2>&1 || warn 'tmux is not installed'
  install_eza
  install_synth_shell
  wire_eza_aliases
  info "configuration: ${PROJECT_DIR}/tmux.conf"
  info 'reload an attached server with: C-a R'
}

main "$@"
