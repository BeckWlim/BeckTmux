#!/usr/bin/env bash

# Opt-in Bash completion setup, shared by terminals inside and outside tmux.
set -Eeuo pipefail

COMPLETION_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPLETION_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/tmux/shell"
COMPLETION_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}"
COMPLETION_BASHRC="${HOME}/.bashrc"

info() { printf '[completion-setup] %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: setup-completion.sh [--no-install]

Install ble.sh for Bash history suggestions and command-aware completion, then
add a guarded loader to ~/.bashrc. Tab accepts the next suggested word; without
a suggestion, Tab performs normal completion. Existing ~/.blerc is preserved.
Carapace is used automatically if it is already on PATH.

  --no-install  configure an existing ble.sh installation without downloading
  -h, --help    show this help
EOF
}

find_ble() {
  local ble_candidate
  for ble_candidate in "${COMPLETION_DATA_DIR}/blesh/ble.sh" \
    /usr/share/blesh/ble.sh /usr/local/share/blesh/ble.sh; do
    [[ ! -r ${ble_candidate} ]] || return 0
  done
  return 1
}

install_ble() (
  local download_directory
  for dependency in curl tar xz; do
    command -v "${dependency}" >/dev/null 2>&1 || {
      printf '[completion-setup] required command missing: %s\n' "${dependency}" >&2
      return 1
    }
  done
  download_directory=$(mktemp -d "${TMPDIR:-/tmp}/beck-blesh.XXXXXXXX")
  trap 'rm -rf -- "${download_directory}"' EXIT
  info 'downloading the official ble.sh nightly release'
  curl --fail --location --retry 2 \
    https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz \
    --output "${download_directory}/ble-nightly.tar.xz" || return
  tar -xJf "${download_directory}/ble-nightly.tar.xz" -C "${download_directory}" || return
  bash "${download_directory}/ble-nightly/ble.sh" --install "${COMPLETION_DATA_DIR}" || return
  find_ble
)

configure_completion() {
  local source_loader="${COMPLETION_PROJECT_DIR}/shell/completion.bash"
  local target_loader="${COMPLETION_CONFIG_DIR}/completion.bash"
  [[ -r ${source_loader} ]] || { printf 'Missing loader: %s\n' "${source_loader}" >&2; return 1; }
  mkdir -p "${COMPLETION_CONFIG_DIR}"
  if [[ ! -e ${target_loader} || ! ${source_loader} -ef ${target_loader} ]]; then
    cp -p "${source_loader}" "${target_loader}"
  fi

  local marker='# >>> beck tmux Bash completion >>>'
  if [[ -f ${COMPLETION_BASHRC} ]] && grep -Fqx "${marker}" "${COMPLETION_BASHRC}"; then
    info 'Bash completion loader already configured'
    return
  fi
  if [[ -e ${COMPLETION_BASHRC} ]]; then
    local backup_path
    backup_path=$(mktemp "${COMPLETION_BASHRC}.bak.XXXXXXXX")
    cp -p "${COMPLETION_BASHRC}" "${backup_path}"
    info "saved existing Bash configuration to ${backup_path}"
  fi
  cat >>"${COMPLETION_BASHRC}" <<'EOF'

# >>> beck tmux Bash completion >>>
if [[ $- == *i* && -r "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/shell/completion.bash" ]]; then
  source "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/shell/completion.bash"
fi
# <<< beck tmux Bash completion <<<
EOF
  info 'added the completion loader to ~/.bashrc'
}

main() {
  local no_install=0
  while (($#)); do
    case "$1" in
      --no-install) no_install=1 ;;
      -h|--help) usage; return ;;
      *) usage >&2; return 2 ;;
    esac
    shift
  done
  if ! find_ble; then
    if ((no_install)); then
      printf '[completion-setup] ble.sh is not installed; rerun without --no-install\n' >&2
      return 1
    fi
    install_ble || return
  fi
  configure_completion
  info 'open a new Bash shell to enable the completion setup'
  if ! command -v carapace >/dev/null 2>&1; then
    info 'using Bash programmable completion; install carapace-bin for additional completers and descriptions'
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
