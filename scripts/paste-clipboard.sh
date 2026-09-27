#!/usr/bin/env bash
# Read the OS clipboard and paste into the pane captured when the key was pressed.
set -euo pipefail
if [[ "${1:-}" == --help ]]; then
  printf 'Usage: paste-clipboard.sh SOCKET PANE\n'
  exit 0
fi
[[ $# -eq 2 ]] || exit 2
readonly clipboard_socket="$1"
readonly clipboard_pane="$2"
clipboard_file="$(mktemp /tmp/beck-tmux-paste.XXXXXXXX)"
readonly clipboard_buffer="beck-paste-${clipboard_file##*/}"
cleanup() {
  tmux -S "$clipboard_socket" delete-buffer -b "$clipboard_buffer" 2>/dev/null || true
  rm -f -- "$clipboard_file"
}
trap cleanup EXIT
read_clipboard() {
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-paste >/dev/null 2>&1; then
    wl-paste --no-newline
  elif [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -out
  elif [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --output
  elif command -v pbpaste >/dev/null 2>&1; then
    pbpaste
  else
    return 1
  fi
}
if ! read_clipboard > "$clipboard_file"; then
  tmux -S "$clipboard_socket" display-message -t "$clipboard_pane" 'Cannot read system clipboard; use your terminal paste shortcut'
  exit 1
fi
[[ -s "$clipboard_file" ]] || exit 0
# Abort if the shell has handed the pane to another application during the read.
clipboard_command="$(tmux -S "$clipboard_socket" display-message -p -t "$clipboard_pane" '#{pane_current_command}')"
case "${clipboard_command##*/}" in
  bash|zsh|fish|sh|dash) ;;
  *) exit 0 ;;
esac
tmux -S "$clipboard_socket" load-buffer -b "$clipboard_buffer" "$clipboard_file"
tmux -S "$clipboard_socket" paste-buffer -p -r -d -b "$clipboard_buffer" -t "$clipboard_pane"
