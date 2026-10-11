#!/usr/bin/env bash

# Exercise setup in fixture paths and optionally test real keystrokes in tmux.
set -Eeuo pipefail
readonly COMPLETION_TEST_PROJECT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly COMPLETION_TEST_DIR="$(mktemp -d /tmp/beck-completion-tests.XXXXXXXX)"
readonly COMPLETION_TEST_SOCKET="${COMPLETION_TEST_DIR}/server.sock"
completion_test_server_started=0
cleanup_completion_tests() {
  if ((completion_test_server_started)); then
    tmux -S "${COMPLETION_TEST_SOCKET}" kill-server >/dev/null 2>&1 || true
  fi
  rm -rf -- "${COMPLETION_TEST_DIR}"
}
trap cleanup_completion_tests EXIT
fail() { printf '[completion-test] FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf '[completion-test] ok: %s\n' "$*"; }

# Avoid downloads and keep HOME unchanged: override only installer destinations.
(
  source "${COMPLETION_TEST_PROJECT}/scripts/setup.sh"
  COMPLETION_CONFIG_DIR="${COMPLETION_TEST_DIR}/config/tmux/shell"
  COMPLETION_DATA_DIR="${COMPLETION_TEST_DIR}/data"
  COMPLETION_NO_INSTALL=1
  COMPLETION_BASHRC="${COMPLETION_TEST_DIR}/bashrc"
  printf '# existing shell customizations\nalias keep_me=true\n' >"${COMPLETION_BASHRC}"
  cp "${COMPLETION_BASHRC}" "${COMPLETION_TEST_DIR}/original-bashrc"
  if ! find_ble; then
    if setup_completion; then
      fail 'missing ble.sh accepted by --completion-no-install'
    fi
    cmp -s "${COMPLETION_BASHRC}" "${COMPLETION_TEST_DIR}/original-bashrc" || \
      fail 'missing ble.sh modified Bash configuration'
    pass '--completion-no-install fails without changing the shell when ble.sh is missing'
  else
    printf '[completion-test] SKIP: missing-install fixture needs no system ble.sh\n'
  fi

  mkdir -p "${COMPLETION_DATA_DIR}/blesh"
  printf '# fixture installed ble.sh\n' >"${COMPLETION_DATA_DIR}/blesh/ble.sh"
  setup_completion
  cp "${COMPLETION_BASHRC}" "${COMPLETION_TEST_DIR}/first-bashrc"
  setup_completion
  cmp -s "${COMPLETION_BASHRC}" "${COMPLETION_TEST_DIR}/first-bashrc" || fail 'loader duplicated'
  bash -n "${COMPLETION_BASHRC}"
  grep -q '^alias keep_me=true$' "${COMPLETION_BASHRC}" || fail 'existing configuration removed'
  shopt -s nullglob
  backups=("${COMPLETION_BASHRC}".bak.*)
  [[ ${#backups[@]} == 1 ]] || fail 'expected one Bash configuration backup'
  cmp -s "${backups[0]}" "${COMPLETION_TEST_DIR}/original-bashrc" || fail 'backup changed contents'
  cmp -s "${COMPLETION_CONFIG_DIR}/completion.bash" \
    "${COMPLETION_TEST_PROJECT}/shell/completion.bash" || fail 'loader deployment failed'
  pass 'setup preserves customizations, backs up once, and is idempotent'
)

bash -c 'source "$1"; [[ ! ${BLE_VERSION-} ]]' test \
  "${COMPLETION_TEST_PROJECT}/shell/completion.bash" || fail 'noninteractive loader did not return cleanly'
pass 'noninteractive shells skip the completion loader'

test_ble_root="${BECK_TEST_BLE_ROOT:-${XDG_DATA_HOME:-${HOME}/.local/share}/blesh}"
if [[ ! -r ${test_ble_root}/ble.sh ]]; then
  printf '[completion-test] SKIP: real-key tests need ble.sh; set BECK_TEST_BLE_ROOT to its directory\n'
  exit 0
fi
command -v tmux >/dev/null || fail 'tmux is required for real-key tests'
mkdir -p "${COMPLETION_TEST_DIR}/interactive-data" "${COMPLETION_TEST_DIR}/cache"
ln -s "${test_ble_root}" "${COMPLETION_TEST_DIR}/interactive-data/blesh"
cat >"${COMPLETION_TEST_DIR}/interactive.bashrc" <<'EOF'
PS1=$'completion-test\n$ '
HISTFILE="${BECK_COMPLETION_TEST_DIR}/history"
PROMPT_COMMAND=':'
if command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="${BECK_COMPLETION_TEST_PROJECT}/shell/starship.toml"
  eval "$(starship init bash)"
fi
source "${BECK_TEST_BLE_ROOT}/ble.sh" --attach=none --rcfile /dev/null
source "${BECK_COMPLETION_TEST_PROJECT}/shell/completion.bash"
function beck-test/count-prompts { ((_beck_test_prompt_count+=1)); }
PROMPT_COMMAND+=(beck-test/count-prompts)
ble-import core-complete
ble-face --color=never auto_complete menu_complete_selected menu_complete_match beck_vim_mode \
  >"${BECK_COMPLETION_TEST_DIR}/theme-faces"
function ble/widget/beck-test/snapshot {
  printf '%s\n' "${_ble_edit_str}" >"${BECK_COMPLETION_TEST_DIR}/input-text"
  printf '%s\n' "${_ble_decode_keymap}" >"${BECK_COMPLETION_TEST_DIR}/input-keymap"
  printf '%s\n' "${_ble_edit_mark_active}" >"${BECK_COMPLETION_TEST_DIR}/input-selection"
  printf '%s\n' "${_beck_test_prompt_count:-0}" >"${BECK_COMPLETION_TEST_DIR}/prompt-count"
  printf '%s\n' "${COLUMNS}" >"${BECK_COMPLETION_TEST_DIR}/input-columns"
  printf '%s\n' "${_ble_edit_str::_ble_edit_ind}" >"${BECK_COMPLETION_TEST_DIR}/snapshot"
}
ble-bind -f 'C-x C-t' beck-test/snapshot
ble-bind -m vi_nmap -f 'C-x C-t' beck-test/snapshot
ble-bind -m auto_complete -f 'C-x C-t' beck-test/snapshot
ble-bind -m menu_complete -f 'C-x C-t' beck-test/snapshot
function beck-choice { printf 'executed\n' >"${BECK_COMPLETION_TEST_DIR}/executed"; }
complete -W 'alpha beta gamma' beck-choice
history -c
history -s 'printf history-word-one history-word-two'
printf 'ready\n' >"${BECK_COMPLETION_TEST_DIR}/ready"
EOF

printf 'source-file "%s"\n' "${COMPLETION_TEST_PROJECT}/tmux.conf" >"${COMPLETION_TEST_DIR}/tmux.conf"
cat >>"${COMPLETION_TEST_DIR}/tmux.conf" <<'EOF'
set -g @beck_default_cursor '#123456'
set -g @beck_default_muted '#9a9b9c'
set -g @beck_default_green '#abcdef'
EOF

env -u TMUX \
  BECK_COMPLETION_TEST_DIR="${COMPLETION_TEST_DIR}" \
  BECK_COMPLETION_TEST_PROJECT="${COMPLETION_TEST_PROJECT}" \
  BECK_TEST_BLE_ROOT="${test_ble_root}" \
  XDG_DATA_HOME="${COMPLETION_TEST_DIR}/interactive-data" \
  XDG_CACHE_HOME="${COMPLETION_TEST_DIR}/cache" \
  tmux -S "${COMPLETION_TEST_SOCKET}" -f "${COMPLETION_TEST_DIR}/tmux.conf" new-session -d -s completion-test \
    -x 160 -y 24 \
    bash --noprofile --rcfile "${COMPLETION_TEST_DIR}/interactive.bashrc" -i
completion_test_server_started=1

wait_for_file() {
  local awaited_file="$1" attempt
  for ((attempt=0; attempt<100; attempt++)); do
    [[ ! -s ${awaited_file} ]] || return 0
    sleep 0.05
  done
  tmux -S "${COMPLETION_TEST_SOCKET}" capture-pane -p >&2 || true
  fail "timed out waiting for ${awaited_file}"
}
send_key() { tmux -S "${COMPLETION_TEST_SOCKET}" send-keys "$@"; }
wait_for_mode_tag() {
  local expected_mode="$1" attempt pane_text row
  for ((attempt=0; attempt<100; attempt++)); do
    pane_text=$(tmux -S "${COMPLETION_TEST_SOCKET}" capture-pane -p)
    while IFS= read -r row; do
      # The tag follows context text, without padding to the pane's right edge.
      if [[ ${row} == *"[${expected_mode}]"* ]]; then
        return 0
      fi
    done <<<"${pane_text}"
    sleep 0.05
  done
  printf '%s\n' "${pane_text}" >&2
  fail "prompt suffix ${expected_mode} tag did not render"
}
snapshot() {
  rm -f -- "${COMPLETION_TEST_DIR}/snapshot"
  send_key C-x C-t
  wait_for_file "${COMPLETION_TEST_DIR}/snapshot"
  snapshot_text=$(cat "${COMPLETION_TEST_DIR}/snapshot")
}
wait_for_file "${COMPLETION_TEST_DIR}/ready"
wait_for_mode_tag INSERT
grep -q 'auto_complete=fg=#9a9b9c' "${COMPLETION_TEST_DIR}/theme-faces" || fail 'suggestions ignored tmux muted colour'
grep -qx 'ble-face beck_vim_mode=fg=#9a9b9c' "${COMPLETION_TEST_DIR}/theme-faces" || fail 'mode tag must use the muted foreground and default background'
grep -q 'menu_complete_selected=.*bg=#123456' "${COMPLETION_TEST_DIR}/theme-faces" || fail 'selection ignored tmux selection colour'
grep -q 'menu_complete_match=.*fg=#abcdef' "${COMPLETION_TEST_DIR}/theme-faces" || fail 'matches ignored tmux focus colour'
pass 'completion colours follow the configured tmux palette roles'
sleep 0.5
send_key -l 'printf his'
sleep 0.5
send_key Tab
snapshot
[[ ${snapshot_text} == 'printf history-word-one ' ]] || fail "Tab accepted the wrong history text: ${snapshot_text}"
send_key Tab
snapshot
[[ ${snapshot_text} == 'printf history-word-one history-word-two' ]] || fail 'second Tab did not accept the next word'
pass 'real Tab accepts history suggestions one word at a time'

send_key C-c
send_key -l 'printf his'
sleep 0.5
snapshot
[[ $(cat "${COMPLETION_TEST_DIR}/input-keymap") == auto_complete ]] || fail 'history hint did not appear'
send_key C-o
snapshot
[[ $(cat "${COMPLETION_TEST_DIR}/input-text") == 'printf his' &&
   $(cat "${COMPLETION_TEST_DIR}/input-keymap") == vi_nmap ]] || \
  fail 'Ctrl+O did not dismiss the hint and enter Normal mode without changing input'
pass 'Ctrl+O dismisses an inline hint and enters Normal mode without changing input'
for newline_key in C-n M-Enter; do
  send_key C-c
  send_key -l 'printf his'
  sleep 0.5
  snapshot
  [[ $(cat "${COMPLETION_TEST_DIR}/input-keymap") == auto_complete ]] || fail "history hint did not appear before ${newline_key}"
  send_key "${newline_key}"
  snapshot
  printf 'printf his\n\n' >"${COMPLETION_TEST_DIR}/expected-newline"
  cmp -s "${COMPLETION_TEST_DIR}/input-text" "${COMPLETION_TEST_DIR}/expected-newline" || \
    fail "${newline_key} accepted the hint or submitted input instead of inserting a newline"
  [[ $(cat "${COMPLETION_TEST_DIR}/input-keymap") == vi_imap ]] || fail "${newline_key} left Insert mode"
  pass "${newline_key} dismisses an inline hint and inserts a newline without submitting"
done

send_key C-c
send_key -l 'git log --on'
sleep 0.5
send_key Tab
snapshot
[[ ${snapshot_text} == 'git log --oneline '* ]] || fail "Git option completion failed: ${snapshot_text}"
pass 'Git subcommand options complete through the installed Bash completer'

send_key C-c
send_key -l 'beck-choice '
sleep 0.3
send_key Tab
sleep 0.2
send_key Tab
snapshot
first_choice=${snapshot_text}
send_key Tab
snapshot
second_choice=${snapshot_text}
[[ ${first_choice} == 'beck-choice alpha'* && ${second_choice} == 'beck-choice beta'* ]] || \
  fail "Tab did not cycle menu choices: ${first_choice} / ${second_choice}"
send_key BTab
snapshot
[[ ${snapshot_text} == "${first_choice}" ]] || fail 'Shift-Tab did not cycle backward'
send_key Enter
snapshot
[[ ! -e ${COMPLETION_TEST_DIR}/executed ]] || fail 'confirming a completion executed the command'
[[ ${snapshot_text} == 'beck-choice alpha '* ]] || fail 'Enter did not accept the menu selection'
pass 'Tab and Shift-Tab cycle choices; Enter accepts without running the command'

send_key C-c
printf -v original_command 'printf "%%s" "%0120d old value"' 0
send_key -l "${original_command}"
snapshot
mode_prompt_count=$(cat "${COMPLETION_TEST_DIR}/prompt-count")
send_key Escape
send_key -l 'hci"new value'
send_key C-o
wait_for_mode_tag NORMAL
snapshot
[[ $(cat "${COMPLETION_TEST_DIR}/input-text") == 'printf "%s" "new value"' ]] || \
  fail 'Vim quoted text object did not replace the current argument'
send_key -l '0w'
snapshot
wait_for_mode_tag NORMAL
for visual_key in v V C-v; do
  if [[ ${visual_key} == C-v ]]; then
    send_key C-v
  else
    send_key -l "${visual_key}"
  fi
  wait_for_mode_tag VISUAL
  send_key -l 'li'
  snapshot
  wait_for_mode_tag INSERT
  [[ $(cat "${COMPLETION_TEST_DIR}/input-keymap") == vi_imap &&
     ! $(cat "${COMPLETION_TEST_DIR}/input-selection") &&
     $(cat "${COMPLETION_TEST_DIR}/input-text") == 'printf "%s" "new value"' ]] || \
    fail "i did not leave ${visual_key} selection intact and return to Insert mode"
  send_key Escape
  wait_for_mode_tag NORMAL
done
snapshot
[[ $(cat "${COMPLETION_TEST_DIR}/prompt-count") == "${mode_prompt_count}" ]] || \
  fail 'mode switches reran the prompt command instead of updating only the tag'
[[ $(cat "${COMPLETION_TEST_DIR}/input-keymap") == vi_nmap ]] || \
  fail 'C-o did not keep shell Normal mode active after motions'
[[ $(tmux -S "${COMPLETION_TEST_SOCKET}" display-message -p '#{pane_in_mode}') == 0 ]] || \
  fail 'shell Vim editing entered tmux scrollback'
pass 'Escape enters shell Vim editing and C-o keeps Normal mode while tmux remains in INPUT'
pass 'prompt suffix mode tag follows Insert, Normal, and Visual modes'
pass 'i leaves character, line, and block Visual modes without changing command text'

send_key -l '0x'
tmux -S "${COMPLETION_TEST_SOCKET}" copy-mode
[[ $(tmux -S "${COMPLETION_TEST_SOCKET}" display-message -p '#{pane_mode}') == copy-mode ]] || \
  fail 'tmux scrollback did not open independently of shell Normal mode'
send_key q
snapshot
[[ $(cat "${COMPLETION_TEST_DIR}/input-keymap") == vi_nmap &&
   $(cat "${COMPLETION_TEST_DIR}/input-text") == 'rintf "%s" "new value"' ]] || \
  fail 'leaving tmux scrollback changed the shell editing state'
send_key -l 'u'
snapshot
[[ $(cat "${COMPLETION_TEST_DIR}/input-text") == 'printf "%s" "new value"' ]] || \
  fail 'Vim undo did not restore the deleted character after returning from scrollback'
send_key -l 'A!'
snapshot
wait_for_mode_tag INSERT
[[ $(cat "${COMPLETION_TEST_DIR}/input-text") == 'printf "%s" "new value"!' &&
   $(cat "${COMPLETION_TEST_DIR}/input-keymap") == vi_imap ]] || \
  fail 'A did not return to shell Insert mode at the end of the command'
pass 'tmux scrollback preserves shell Normal mode, input text, undo, and return to Insert'
send_key Escape
send_key C-c
snapshot
[[ ! $(cat "${COMPLETION_TEST_DIR}/input-text") &&
   $(cat "${COMPLETION_TEST_DIR}/input-keymap") == vi_imap ]] || \
  fail 'Ctrl-C in shell Normal mode did not abandon input and return to Insert mode'
pass 'Ctrl-C abandons the current command from shell Normal mode'

# Search should move within the current command, including from its end.
send_key -l 'printf alpha beta alpha'
send_key Escape
wait_for_mode_tag NORMAL
send_key -l '/alpha'
send_key Enter
snapshot
[[ ${snapshot_text} == 'printf ' &&
   $(cat "${COMPLETION_TEST_DIR}/input-text") == 'printf alpha beta alpha' &&
   $(cat "${COMPLETION_TEST_DIR}/input-keymap") == vi_nmap ]] || \
  fail 'Normal-mode / did not wrap to the first match in the current command'
send_key -l n
snapshot
[[ ${snapshot_text} == 'printf alpha beta ' ]] || fail 'n did not advance to the next match'
send_key -l n
snapshot
[[ ${snapshot_text} == 'printf ' ]] || fail 'n did not wrap within the current command'
send_key -l N
snapshot
[[ ${snapshot_text} == 'printf alpha beta ' ]] || fail 'N did not reverse and wrap the search'
send_key -l n
snapshot
[[ ${snapshot_text} == 'printf ' ]] || fail 'N changed the original search direction'
send_key -l '?alpha'
send_key Enter
snapshot
[[ ${snapshot_text} == 'printf alpha beta ' ]] || fail '? did not wrap to the previous match'
send_key -l n
snapshot
[[ ${snapshot_text} == 'printf ' ]] || fail 'n did not repeat the backward search'
send_key -l '/history-word-one'
send_key Enter
snapshot
[[ ${snapshot_text} == 'printf ' &&
   $(cat "${COMPLETION_TEST_DIR}/input-text") == 'printf alpha beta alpha' ]] || \
  fail 'a missing match changed the cursor or replaced input with command history'
send_key -l '/alpha'
# Allow the search prompt to render before cancelling it, then wait for Escape
# to resolve instead of combining it with the snapshot's control-key sequence.
for ((search_attempt=0; search_attempt<100; search_attempt++)); do
  [[ $(tmux -S "${COMPLETION_TEST_SOCKET}" capture-pane -p) == *'/alpha'* ]] && break
  sleep 0.05
done
send_key Escape
for ((search_attempt=0; search_attempt<100; search_attempt++)); do
  [[ $(tmux -S "${COMPLETION_TEST_SOCKET}" capture-pane -p) == *'/alpha'* ]] || break
  sleep 0.05
done
snapshot
[[ ${snapshot_text} == 'printf ' &&
   $(cat "${COMPLETION_TEST_DIR}/input-keymap") == vi_nmap ]] || \
  fail 'cancelling a search changed the cursor or shell mode'
pass 'Normal-mode / and ? search the current command with wrapping, n/N repeats, and cancellation'
send_key C-c

# Ctrl+N splits the command at the Insert-mode cursor, including inside a line.
send_key -l 'printf split-point'
send_key C-o
wait_for_mode_tag NORMAL
send_key -l '0wi'
send_key C-n
snapshot
[[ $(cat "${COMPLETION_TEST_DIR}/input-text") == $'printf \nsplit-point' &&
   $(cat "${COMPLETION_TEST_DIR}/input-keymap") == vi_imap ]] || \
  fail 'Ctrl+N did not split the command at the cursor and stay in Insert mode'
send_key C-c
pass 'Insert-mode Ctrl+N inserts a newline at the cursor without submitting'

for submit_mode in normal insert insert-reloaded; do
  if [[ ${submit_mode} == insert-reloaded ]]; then
    send_key -l 'source "$BECK_COMPLETION_TEST_PROJECT/shell/completion.bash"; printf ready > "$BECK_COMPLETION_TEST_DIR/reloaded"'
    send_key Enter
    wait_for_file "${COMPLETION_TEST_DIR}/reloaded"
    wait_for_mode_tag INSERT
  fi
  send_key -l 'printf one > "$BECK_COMPLETION_TEST_DIR/submit-'
  send_key -l "${submit_mode}"
  send_key -l '"'
  if [[ ${submit_mode} == insert ]]; then
    send_key M-Enter
  else
    send_key C-n
  fi
  send_key -l 'printf two >> "$BECK_COMPLETION_TEST_DIR/submit-'
  send_key -l "${submit_mode}"
  send_key -l '"'
  send_key Escape
  wait_for_mode_tag NORMAL
  if [[ ${submit_mode} != normal ]]; then
    send_key -l '0wi'
    wait_for_mode_tag INSERT
  fi
  snapshot
  [[ $(cat "${COMPLETION_TEST_DIR}/input-text") == *$'\n'* ]] || \
    fail "newline shortcut did not insert an explicit newline: $(cat "${COMPLETION_TEST_DIR}/input-text")"
  send_key Enter
  wait_for_file "${COMPLETION_TEST_DIR}/submit-${submit_mode}"
  [[ $(cat "${COMPLETION_TEST_DIR}/submit-${submit_mode}") == onetwo ]] || \
    fail "Enter did not submit the multiline command from ${submit_mode} mode"
  wait_for_mode_tag INSERT
done
pass 'Enter submits multiline commands after cursor movement and reloading; Ctrl+N and Alt+Enter insert newlines'

# Start with a clean screen to distinguish resize artifacts from old commands.
rm -f -- "${COMPLETION_TEST_DIR}/ready"
tmux -S "${COMPLETION_TEST_SOCKET}" new-window -n resize-test \
  bash --noprofile --rcfile "${COMPLETION_TEST_DIR}/interactive.bashrc" -i
wait_for_file "${COMPLETION_TEST_DIR}/ready"
wait_for_mode_tag INSERT
send_key -l "${original_command}"
send_key Escape
wait_for_mode_tag NORMAL
for resize_width in 96 64 120 160; do
  tmux -S "${COMPLETION_TEST_SOCKET}" resize-window -x "${resize_width}" -y 24
  for ((resize_attempt=0; resize_attempt<100; resize_attempt++)); do
    snapshot
    [[ $(cat "${COMPLETION_TEST_DIR}/input-columns") == "${resize_width}" ]] && break
    sleep 0.05
  done
  [[ $(cat "${COMPLETION_TEST_DIR}/input-columns") == "${resize_width}" ]] || \
    fail "shell did not process the resize to ${resize_width} columns"
  wait_for_mode_tag NORMAL
  resize_screen=$(tmux -S "${COMPLETION_TEST_SOCKET}" capture-pane -p -S -)
  while IFS= read -r resize_row; do
    [[ ${resize_row} == *'['* || ${resize_row} == *']'* ]] || continue
    if [[ ${resize_row} != *' [NORMAL]' || ${resize_row} == *'  [NORMAL]' ||
          ! ${resize_row%" [NORMAL]"} =~ [^[:space:]] ]]; then
      printf '%s\n' "${resize_screen}" >&2
      fail "resize to ${resize_width} columns detached the tag from its context text"
    fi
  done <<<"${resize_screen}"
  snapshot
  [[ $(cat "${COMPLETION_TEST_DIR}/input-text") == "${original_command}" &&
     $(cat "${COMPLETION_TEST_DIR}/input-keymap") == vi_nmap ]] || \
    fail 'resizing changed command input or shell Normal mode'
done
pass 'repeated shrinking and widening keep the tag attached to context and preserve long input'
printf '[completion-test] PASS\n'
