#!/usr/bin/env bash

# Clipboard policy shared by tmux copy mode, independent of pane applications.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: clipboard.sh use-native [CLIENT_PID]
       clipboard.sh copy-native

use-native exits 0 when the calling client should use a local desktop provider.
SSH clients exit 1 so tmux can send OSC 52 to their terminal instead. On Linux,
the client's /proc environment takes precedence over the shared pane/session
SSH variables. Without a readable client environment, use the session variables.

copy-native reads UTF-8 from stdin and writes to Wayland or WSL's Windows bridge.
It leaves tmux paste-buffer management and OSC 52 delivery to tmux itself.
EOF
}

native_provider() {
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1; then
    printf '%s' wayland
  elif command -v clip.exe >/dev/null 2>&1 && command -v iconv >/dev/null 2>&1; then
    printf '%s' windows
  else
    return 1
  fi
}

ssh_client() {
  local client_pid="${1:-}"
  if [[ "${client_pid}" =~ ^[0-9]+$ && -r "/proc/${client_pid}/environ" ]]; then
    grep -zqE '^SSH_(CONNECTION|TTY)=.+' "/proc/${client_pid}/environ"
  else
    [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]]
  fi
}

case "${1:---help}" in
  use-native)
    ssh_client "${2:-}" && exit 1
    native_provider >/dev/null
    ;;
  copy-native)
    case "$(native_provider)" in
      wayland) exec wl-copy --type text/plain ;;
      windows) iconv -f UTF-8 -t UTF-16LE | clip.exe ;;
      *) printf '%s\n' '[tmux-clipboard] No native clipboard provider' >&2; exit 1 ;;
    esac
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
