#!/usr/bin/env bash

# Clipboard copying and optional local Linux history for BeckTmux.
set -Eeuo pipefail

PROJECT_DIRECTORY="${BECK_TMUX_DIRECTORY:-${XDG_CONFIG_HOME:-${HOME}/.config}/tmux}"
export PATH="${PATH}:${PROJECT_DIRECTORY}/plugins/clipboard-runtime/usr/bin"
temporary_directory=""
paste_buffer=""
entry_count=0
picker_colors=""
popup_style=""
popup_border_style=""
picker_cursor_hidden=0

usage() {
  cat <<'EOF'
Usage: clipboard.sh use-native [CLIENT_PID]
       clipboard.sh copy-native
       clipboard.sh launch CLIENT_TTY PANE_ID [CLIENT_PID]
       clipboard.sh pick PANE_ID [SNAPSHOT_DIRECTORY]
       clipboard.sh start

use-native chooses Wayland for a local client; SSH clients use tmux OSC 52.
copy-native reads UTF-8 from stdin and writes to the Wayland clipboard.
Tmux owns paste buffers and OSC 52 delivery, including SSH into WSL.

C-s f opens searchable local Linux clipboard history in a tmux popup.
j/k selects, o or Enter pastes, and q or Escape quits selection mode.
/ searches; Ctrl-G returns to selection; Ctrl-Q or Escape quits search mode.
History uses CopyQ and fzf, installed with scripts/setup.sh --clipboard.
SSH clients cannot access desktop clipboard history.
EOF
}

native_provider() {
  [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null 2>&1
}

ssh_client() {
  local client_pid="${1:-}"
  if [[ "${client_pid}" =~ ^[0-9]+$ && -r "/proc/${client_pid}/environ" ]]; then
    grep -zqE '^SSH_(CONNECTION|TTY)=.+' "/proc/${client_pid}/environ"
  else
    [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]]
  fi
}

cleanup() {
  if ((picker_cursor_hidden)) && [[ -t 2 ]]; then
    printf '\033[?25h' >&2
  fi
  if [[ -n "${paste_buffer}" ]]; then
    tmux delete-buffer -b "${paste_buffer}" 2>/dev/null || true
  fi
  if [[ -n "${temporary_directory}" ]]; then
    rm -rf -- "${temporary_directory}"
  fi
}

hide_picker_cursor() {
  local terminal_output=""
  # Older fzf releases show the cursor at the end of every redraw. Rewrite
  # only that terminal command, streaming at its final byte rather than waiting
  # for newlines (fullscreen redraws need not contain any).
  while IFS= read -r -d h terminal_output; do
    if [[ "${terminal_output}" == *$'\033[?25' ]]; then
      printf '%sl' "${terminal_output}"
    else
      printf '%sh' "${terminal_output}"
    fi
  done
  printf '%s' "${terminal_output}"
}

run_picker() {
  if ((picker_cursor_hidden)); then
    # fzf reads keys and terminal dimensions from /dev/tty. Filter its UI on
    # stderr while keeping the selected entry on stdout and its exit status.
    { fzf "$@" 2>&1 1>&3 | hide_picker_cursor >&2; } 3>&1
  else
    fzf "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[clipboard-history] Missing %s; run scripts/setup.sh --clipboard\n' "$1" >&2
    return 1
  }
}

start_provider() {
  require_command copyq
  if copyq --help | grep -q -- --start-server; then
    copyq --start-server count >/dev/null
  else
    # CopyQ in older Pop!_OS/Ubuntu repositories lacks --start-server.
    if ! copyq count >/dev/null 2>&1; then
      copyq >/dev/null 2>&1 &
      local attempt
      for attempt in {1..50}; do
        copyq count >/dev/null 2>&1 && return
        sleep 0.1
      done
      printf '[clipboard-history] CopyQ did not start in this desktop session.\n' >&2
      return 1
    fi
  fi
}

read_palette() {
  local palette_bg palette_fg palette_cursor palette_border palette_muted palette_green palette_cyan
  IFS='|' read -r palette_bg palette_fg palette_cursor palette_border palette_muted palette_green palette_cyan < <(
    tmux display-message -p -t "$1" \
      '#{E:@beck_ui_bg}|#{E:@beck_ui_fg}|#{E:@beck_ui_cursor}|#{E:@beck_ui_border}|#{E:@beck_ui_muted}|#{E:@beck_ui_green}|#{E:@beck_ui_cyan}')
  palette_bg="${palette_bg:-default}"; palette_fg="${palette_fg:-default}"
  palette_cursor="${palette_cursor:-default}"; palette_border="${palette_border:-default}"
  palette_muted="${palette_muted:-default}"; palette_green="${palette_green:-default}"
  palette_cyan="${palette_cyan:-default}"
  popup_style="fg=${palette_fg},bg=${palette_bg}"
  popup_border_style="fg=${palette_border},bg=${palette_bg}"
  # fzf spells the terminal's default colour -1. All roles come from tmux;
  # the list, preview and popup share the same background and neutral borders.
  picker_colors="fg:${palette_fg},bg:${palette_bg},fg+:${palette_fg},bg+:${palette_cursor},gutter:${palette_bg}"
  picker_colors+=",hl:${palette_green},hl+:${palette_green},prompt:${palette_green},pointer:${palette_green}"
  picker_colors+=",marker:${palette_green},info:${palette_cyan},header:${palette_muted},border:${palette_border}"
  picker_colors+=",preview-fg:${palette_fg},preview-bg:${palette_bg},query:${palette_fg},disabled:${palette_muted}"
  picker_colors="${picker_colors//default/-1}"
}

prepare_history() {
  local encoded_text preview_text
  require_command base64
  start_provider
  umask 077
  temporary_directory="$(mktemp -d /tmp/beck-clipboard.XXXXXXXX)"
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP
  # Retrieve once so sizing, selection and paste all use the same text snapshot.
  copyq -- eval '
    for (var i = 0; i < size(); ++i) {
      var data = read("text/plain", i);
      var encoded = toBase64(data);
      if (!encoded) continue;
      var preview = str(data).replace(/[\x00-\x1f\x7f-\x9f]/g, " ").slice(0, 200);
      print(encoded + "\t" + preview + "\n");
    }
  ' >"${temporary_directory}/snapshot"
  : >"${temporary_directory}/entries"
  while IFS=$'\t' read -r encoded_text preview_text; do
    [[ -n "${encoded_text}" ]] || continue
    printf '%s' "${encoded_text}" | base64 --decode >"${temporary_directory}/${entry_count}"
    printf '%s\t%s\n' "${entry_count}" "${preview_text}" >>"${temporary_directory}/entries"
    entry_count=$((entry_count + 1))
  done <"${temporary_directory}/snapshot"
}

launch() {
  local client_tty="$1" target_pane="$2" client_pid="${3:-}"
  local client_environment
  # Never read the server desktop's history on behalf of an SSH client.
  if ssh_client "${client_pid}"; then
    tmux display-message -c "${client_tty}" 'Clipboard history is local to the desktop; SSH copying uses OSC 52.'
    return
  fi
  if [[ "${client_pid}" =~ ^[0-9]+$ && -r "/proc/${client_pid}/environ" ]]; then
    # Long-running servers can retain an obsolete desktop environment.
    while IFS= read -r -d '' client_environment; do
      case "${client_environment}" in
        DISPLAY=*|WAYLAND_DISPLAY=*|XDG_RUNTIME_DIR=*|DBUS_SESSION_BUS_ADDRESS=*)
          export "${client_environment}" ;;
      esac
    done <"/proc/${client_pid}/environ"
  fi
  if [[ ! -x "${PROJECT_DIRECTORY}/plugins/tmux-fzf/scripts/clipboard.sh" ]] ||
      ! command -v copyq >/dev/null || ! command -v fzf >/dev/null; then
    tmux display-message -c "${client_tty}" 'Install clipboard history with ~/.config/tmux/scripts/setup.sh --clipboard'
    return
  fi
  prepare_history
  if ((entry_count == 0)); then
    tmux display-message -c "${client_tty}" 'No clipboard text history yet. Copy text in a desktop app, then reopen C-s f.'
    return
  fi
  read_palette "${target_pane}"
  local popup_command popup_height client_height history_count="${entry_count}"
  printf -v popup_command 'bash %q pick %q %q' \
    "${PROJECT_DIRECTORY}/plugins/tmux-fzf/scripts/clipboard.sh" "${target_pane}" "${temporary_directory}"
  # Cap the list at 12 rows; keep enough preview space for short histories.
  ((history_count <= 12)) || history_count=12
  popup_height=$((history_count + 5))
  ((popup_height >= 12)) || popup_height=12
  client_height="$(tmux display-message -p -c "${client_tty}" '#{client_height}')"
  if [[ "${client_height}" =~ ^[0-9]+$ ]] && ((popup_height > client_height - 2)); then
    popup_height=$((client_height - 2))
  fi
  # -e forwards the refreshed desktop context to the popup's process.
  tmux display-popup -c "${client_tty}" -E -w 85% -h "${popup_height}" -T 'System clipboard history' \
    -b single -s "${popup_style}" -S "${popup_border_style}" \
    -e "PATH=${PATH}" -e "BECK_TMUX_DIRECTORY=${PROJECT_DIRECTORY}" \
    -e "BECK_CLIPBOARD_COLORS=${picker_colors}" "${popup_command}"
}

pick() {
  local target_pane="$1" snapshot_directory="${2:-}" selected_entry selected_index picker_key
  local picker_mode=select picker_status=0
  local -a mode_options
  require_command fzf
  if [[ -z "${snapshot_directory}" ]]; then
    prepare_history
    snapshot_directory="${temporary_directory}"
  else
    trap cleanup EXIT
    trap 'exit 130' INT TERM HUP
  fi
  [[ -s "${snapshot_directory}/entries" ]] || return
  if [[ -n "${BECK_CLIPBOARD_COLORS:-}" ]]; then
    picker_colors="${BECK_CLIPBOARD_COLORS}"
  else
    read_palette "${target_pane}"
  fi
  export BECK_CLIPBOARD_SNAPSHOT="${snapshot_directory}"
  # Separate picker modes use actions supported by fzf 0.29 in Pop!_OS 22.04.
  while :; do
    if [[ "${picker_mode}" == select ]]; then
      picker_cursor_hidden=1
      mode_options=(--disabled --bind='j:down,k:up,o:accept,q:abort,change:clear-query' --expect=/ \
        --prompt='Clipboard > ' --header='j/k: select  o/Enter: paste  /: search  q: quit')
    else
      picker_cursor_hidden=0
      mode_options=(--bind='ctrl-q:abort' --expect=ctrl-g \
        --prompt='Search > ' --header='Type to search  Ctrl-G: select  Enter: paste  Ctrl-Q: quit')
    fi
    selected_entry="$(FZF_DEFAULT_OPTS= FZF_DEFAULT_OPTS_FILE= run_picker \
      --no-multi --no-sort --delimiter=$'\t' --with-nth=2.. --layout=reverse \
      --border=none --color="${picker_colors}" "${mode_options[@]}" \
      --preview='cat -- "$BECK_CLIPBOARD_SNAPSHOT"/{1}' --preview-window='right,55%,border-left,wrap' \
      <"${snapshot_directory}/entries")" || picker_status=$?
    case "${picker_status}" in
      0) ;;
      1|130) return 0 ;;
      *) return "${picker_status}" ;;
    esac
    picker_key="${selected_entry%%$'\n'*}"
    case "${picker_key}" in
      /) picker_mode=search ;;
      ctrl-g) picker_mode=select ;;
      '') selected_entry="${selected_entry#*$'\n'}"; break ;;
      *) return 1 ;;
    esac
  done
  selected_index="${selected_entry%%$'\t'*}"
  [[ "${selected_index}" =~ ^[0-9]+$ && -f "${snapshot_directory}/${selected_index}" ]] || return 1
  paste_buffer="beck-clipboard-${snapshot_directory##*/}"
  tmux load-buffer -b "${paste_buffer}" "${snapshot_directory}/${selected_index}"
  # File input preserves trailing newlines; -p honours application bracketed paste.
  tmux paste-buffer -p -r -b "${paste_buffer}" -t "${target_pane}"
}

case "${1:---help}" in
  use-native)
    ssh_client "${2:-}" && exit 1
    native_provider >/dev/null
    ;;
  copy-native)
    native_provider >/dev/null || {
      printf '%s\n' '[tmux-clipboard] No native clipboard provider' >&2
      exit 1
    }
    exec wl-copy --type text/plain
    ;;
  launch) [[ $# -ge 3 && $# -le 4 ]] || exit 2; launch "$2" "$3" "${4:-}" ;;
  pick) [[ $# -ge 2 && $# -le 3 ]] || exit 2; pick "$2" "${3:-}" ;;
  start) start_provider ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
