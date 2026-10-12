#!/usr/bin/env bash

# Exercise history snapshots and paste bytes on a disposable tmux server.
set -Eeuo pipefail
readonly PROJECT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly FIXTURE_DIRECTORY="$(mktemp -d /tmp/beck-history-tests.XXXXXXXX)"
readonly SOCKET_PATH="${FIXTURE_DIRECTORY}/server.sock"
readonly REAL_TMUX="$(command -v tmux)"
real_fzf="$(command -v fzf || true)"
[[ -n "${real_fzf}" ]] || real_fzf="${PROJECT_DIRECTORY}/plugins/clipboard-runtime/usr/bin/fzf"
cleanup() {
  "${REAL_TMUX}" -S "${SOCKET_PATH}" kill-server 2>/dev/null || true
  rm -rf -- "${FIXTURE_DIRECTORY}"
}
trap cleanup EXIT
fail() { printf '[history-test] FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf '[history-test] ok: %s\n' "$*"; }
export BECK_HISTORY_FIXTURE="${FIXTURE_DIRECTORY}" BECK_HISTORY_TMUX="${REAL_TMUX}"
mkdir -p "${FIXTURE_DIRECTORY}/bin" "${FIXTURE_DIRECTORY}/tmp"
cat >"${FIXTURE_DIRECTORY}/bin/copyq" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --help) printf '%s\n' --start-server ;;
  --start-server) printf '2\n' ;;
  --) cat "${BECK_HISTORY_FIXTURE}/snapshot" ;;
  *) exit 2 ;;
esac
EOF
cat >"${FIXTURE_DIRECTORY}/bin/fzf" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${BECK_HISTORY_REAL_FZF:-}" ]]; then
  exec "${BECK_HISTORY_REAL_FZF}" "$@"
fi
cat >"${BECK_HISTORY_FIXTURE}/entries"
printf '%s\n' "$@" >"${BECK_HISTORY_FIXTURE}/fzf-arguments"
case "${BECK_HISTORY_ACTION:-select}" in
  cancel) exit 130 ;;
  error) exit 2 ;;
esac
# A clipboard update while choosing must not change the snapshot's bytes.
printf 'new history\n' >"${BECK_HISTORY_FIXTURE}/snapshot"
printf '\n'
head -1 "${BECK_HISTORY_FIXTURE}/entries"
EOF
cat >"${FIXTURE_DIRECTORY}/bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == display-popup || "$1" == display-message ]]; then
  if [[ "${2:-}" == -p ]]; then
    if [[ "${*: -1}" == '#{client_height}' ]]; then printf '40\n'; exit; fi
    exec "${BECK_HISTORY_TMUX}" -S "${BECK_HISTORY_FIXTURE}/server.sock" "$@"
  fi
  printf '%s\n' "$@" >"${BECK_HISTORY_FIXTURE}/popup-arguments"
  exit
fi
exec "${BECK_HISTORY_TMUX}" -S "${BECK_HISTORY_FIXTURE}/server.sock" "$@"
EOF
chmod +x "${FIXTURE_DIRECTORY}/bin/"*
export PATH="${FIXTURE_DIRECTORY}/bin:${PATH}"
unset WSL_DISTRO_NAME SSH_CONNECTION SSH_TTY
export BECK_TMUX_DIRECTORY="${PROJECT_DIRECTORY}"
env -u TMUX "${REAL_TMUX}" -S "${SOCKET_PATH}" -f "${PROJECT_DIRECTORY}/tmux.conf" \
  new-session -d -s history-test sleep 120
tmux set-option -g @beck_default_bg '#102030'
tmux set-option -g @beck_default_cursor '#304050'
tmux set-option -g @beck_default_border '#506070'
tmux set-option -g @beck_default_green '#90a0b0'

# Include Unicode, literal shell syntax, a percent sign and trailing newlines.
printf '中文 café 😀 %%s $(touch never-run)\\n\nsecond line\n\n' >"${FIXTURE_DIRECTORY}/sample"
make_snapshot() {
  printf '%s\tfirst quiet item\n' "$(base64 -w0 "${FIXTURE_DIRECTORY}/sample")" >"${FIXTURE_DIRECTORY}/snapshot"
  printf 'b3RoZXI=\tother item\n' >>"${FIXTURE_DIRECTORY}/snapshot"
}
sample_bytes="$(wc -c <"${FIXTURE_DIRECTORY}/sample")"
printf '\033[200~' >"${FIXTURE_DIRECTORY}/expected"
cat "${FIXTURE_DIRECTORY}/sample" >>"${FIXTURE_DIRECTORY}/expected"
printf '\033[201~' >>"${FIXTURE_DIRECTORY}/expected"
output_path="${FIXTURE_DIRECTORY}/linux-paste"
pane_id="$(tmux new-window -d -P -F '#{pane_id}' bash -c '
  stty raw -echo
  printf "\033[?2004h"
  touch "$3"
  dd bs=1 count="$1" of="$2" 2>/dev/null
  exec sleep 120
' test "$((sample_bytes + 12))" "${output_path}" "${FIXTURE_DIRECTORY}/linux-ready")"
for attempt in {1..100}; do
  [[ -f "${FIXTURE_DIRECTORY}/linux-ready" ]] && break
  sleep 0.02
done
[[ -f "${FIXTURE_DIRECTORY}/linux-ready" ]] || fail 'paste receiver did not start'
make_snapshot
"${PROJECT_DIRECTORY}/scripts/clipboard.sh" pick "${pane_id}"
grep -qx -- '--preview-window=right,55%,border-left,wrap' "${FIXTURE_DIRECTORY}/fzf-arguments" || fail 'preview is not on the right'
grep -qx -- '--disabled' "${FIXTURE_DIRECTORY}/fzf-arguments" || fail 'picker starts in search mode'
grep -qx -- '--bind=j:down,k:up,o:accept,q:abort,change:clear-query' "${FIXTURE_DIRECTORY}/fzf-arguments" || fail 'selection keys differ'
grep -q -- 'fg:-1,bg:#102030,fg+:-1,bg+:#304050' "${FIXTURE_DIRECTORY}/fzf-arguments" || fail 'picker ignores palette roles'
grep -q -- 'hl:#90a0b0' "${FIXTURE_DIRECTORY}/fzf-arguments" || fail 'matching does not use focus colour'
for attempt in {1..100}; do
  cmp -s "${output_path}" "${FIXTURE_DIRECTORY}/expected" && break
  sleep 0.02
done
if ! cmp -s "${output_path}" "${FIXTURE_DIRECTORY}/expected"; then
  od -An -tx1 "${output_path}" "${FIXTURE_DIRECTORY}/expected" >&2
  fail "linux: paste bytes differ"
fi
[[ -z "$(tmux list-buffers)" ]] || fail 'temporary paste buffer leaked'
pass "linux: snapshot pastes Unicode and trailing newlines with bracketed paste into original pane"
tmux kill-pane -t "${pane_id}"
for picker_action in cancel error; do
  make_snapshot
  picker_status=0
  BECK_HISTORY_ACTION="${picker_action}" "${PROJECT_DIRECTORY}/scripts/clipboard.sh" pick %0 || picker_status=$?
  if [[ "${picker_action}" == cancel ]]; then
    [[ "${picker_status}" == 0 ]] || fail 'cancellation was reported as an error'
  else
    [[ "${picker_status}" == 2 ]] || fail 'picker failure was hidden'
  fi
  [[ -z "$(tmux list-buffers)" ]] || fail 'cancel/error created a paste buffer'
  pass "${picker_action}: nothing is pasted"
done

# Use a fixture plugin marker to test launch even on a clean checkout.
mkdir -p "${FIXTURE_DIRECTORY}/project/plugins/tmux-fzf/scripts"
touch "${FIXTURE_DIRECTORY}/project/plugins/tmux-fzf/scripts/clipboard.sh"
chmod +x "${FIXTURE_DIRECTORY}/project/plugins/tmux-fzf/scripts/clipboard.sh"
make_snapshot
BECK_TMUX_DIRECTORY="${FIXTURE_DIRECTORY}/project" \
  "${PROJECT_DIRECTORY}/scripts/clipboard.sh" launch /dev/pts/fixture %0
grep -qx display-popup "${FIXTURE_DIRECTORY}/popup-arguments" || fail 'popup not opened'
grep -qx /dev/pts/fixture "${FIXTURE_DIRECTORY}/popup-arguments" || fail 'client target missing'
grep -q 'pick %0' "${FIXTURE_DIRECTORY}/popup-arguments" || fail 'pane target missing'
grep -qx 'fg=default,bg=#102030' "${FIXTURE_DIRECTORY}/popup-arguments" || fail 'popup background differs'
grep -qx 'fg=#506070,bg=#102030' "${FIXTURE_DIRECTORY}/popup-arguments" || fail 'popup border differs'
pass 'popup uses calling client and captures original pane'
[[ "$(awk '/^-h$/ {getline; print}' "${FIXTURE_DIRECTORY}/popup-arguments")" == 12 ]] || fail 'short history popup too tall'
for history_index in {1..100}; do
  printf 'b3RoZXI=\titem %s\n' "${history_index}"
done >"${FIXTURE_DIRECTORY}/snapshot"
BECK_TMUX_DIRECTORY="${FIXTURE_DIRECTORY}/project" \
  "${PROJECT_DIRECTORY}/scripts/clipboard.sh" launch /dev/pts/fixture %0
[[ "$(awk '/^-h$/ {getline; print}' "${FIXTURE_DIRECTORY}/popup-arguments")" == 17 ]] || fail 'long history popup not capped'
pass 'popup height follows short history and caps long history at 12 rows'
WSL_DISTRO_NAME=fixture SSH_CONNECTION=fixture "${PROJECT_DIRECTORY}/scripts/clipboard.sh" launch /dev/pts/fixture %0
grep -qx display-message "${FIXTURE_DIRECTORY}/popup-arguments" || fail 'SSH opened desktop history'
pass 'SSH into WSL cannot access server desktop history'

wait_for_picker() {
  local picker_pane="$1" expected_prompt="$2" attempt
  for attempt in {1..100}; do
    [[ "$(tmux capture-pane -p -t "${picker_pane}")" == *"${expected_prompt}"* ]] && return
    sleep 0.02
  done
  fail "picker did not show ${expected_prompt}"
}

assert_picker_cursor() {
  local picker_pane="$1" expected_visibility="$2" attempt
  for attempt in {1..100}; do
    [[ "$(tmux display-message -p -t "${picker_pane}" '#{cursor_flag}')" == "${expected_visibility}" ]] && return
    sleep 0.02
  done
  fail "picker cursor visibility differs: expected ${expected_visibility}"
}

if [[ -x "${real_fzf}" ]]; then
  for key_sequence in down up paste ignore search search-q return quit escape search-quit search-escape; do
    make_snapshot
    expected_path="${FIXTURE_DIRECTORY}/keys-${key_sequence}-expected"
    printf '\033[200~' >"${expected_path}"
    if [[ "${key_sequence}" == up || "${key_sequence}" == ignore || "${key_sequence}" == search-q ]]; then
      cat "${FIXTURE_DIRECTORY}/sample" >>"${expected_path}"
    else
      printf 'other' >>"${expected_path}"
    fi
    printf '\033[201~' >>"${expected_path}"
    byte_count="$(wc -c <"${expected_path}")"
    receiver_pane="$(tmux new-window -d -P -F '#{pane_id}' bash -c '
      stty raw -echo
      printf "\033[?2004h"
      touch "$3"
      dd bs=1 count="$1" of="$2" 2>/dev/null
      exec sleep 120
    ' test "${byte_count}" "${FIXTURE_DIRECTORY}/keys-${key_sequence}-paste" \
      "${FIXTURE_DIRECTORY}/keys-${key_sequence}-ready")"
    for attempt in {1..100}; do
      [[ -f "${FIXTURE_DIRECTORY}/keys-${key_sequence}-ready" ]] && break
      sleep 0.02
    done
    picker_pane="$(tmux new-window -d -P -F '#{pane_id}' bash -c '
      BECK_HISTORY_REAL_FZF="$1" "$2" pick "$3"
      printf done >"$4"
      exec sleep 120
    ' test "${real_fzf}" "${PROJECT_DIRECTORY}/scripts/clipboard.sh" \
      "${receiver_pane}" "${FIXTURE_DIRECTORY}/keys-${key_sequence}-done")"
    wait_for_picker "${picker_pane}" 'Clipboard >'
    assert_picker_cursor "${picker_pane}" 0
    rendered_picker="$(tmux capture-pane -e -p -t "${picker_pane}")"
    [[ "${rendered_picker}" == *'48;2;16;32;48'* ]] || fail 'real picker background does not follow palette'
    case "${key_sequence}" in
      down)
        tmux send-keys -t "${picker_pane}" j
        wait_for_picker "${picker_pane}" '> other item'
        assert_picker_cursor "${picker_pane}" 0
        tmux send-keys -t "${picker_pane}" Enter ;;
      up) tmux send-keys -t "${picker_pane}" j k Enter ;;
      paste) tmux send-keys -t "${picker_pane}" j o ;;
      ignore)
        tmux send-keys -t "${picker_pane}" text
        wait_for_picker "${picker_pane}" '2/2'
        assert_picker_cursor "${picker_pane}" 0
        tmux send-keys -t "${picker_pane}" Enter ;;
      search|search-q|search-quit|search-escape|return)
        tmux send-keys -t "${picker_pane}" /
        wait_for_picker "${picker_pane}" 'Search >'
        assert_picker_cursor "${picker_pane}" 1
        if [[ "${key_sequence}" == search || "${key_sequence}" == search-q ]]; then
          search_text=other
          [[ "${key_sequence}" != search-q ]] || search_text=quiet
          tmux send-keys -t "${picker_pane}" "${search_text}"
          wait_for_picker "${picker_pane}" '1/2'
          assert_picker_cursor "${picker_pane}" 1
          tmux send-keys -t "${picker_pane}" Enter
        elif [[ "${key_sequence}" == search-quit ]]; then
          tmux send-keys -t "${picker_pane}" C-q
        elif [[ "${key_sequence}" == search-escape ]]; then
          tmux send-keys -t "${picker_pane}" Escape
        else
          tmux send-keys -t "${picker_pane}" C-g
          wait_for_picker "${picker_pane}" 'Clipboard >'
          assert_picker_cursor "${picker_pane}" 0
          tmux send-keys -t "${picker_pane}" j Enter
        fi ;;
      quit) tmux send-keys -t "${picker_pane}" q ;;
      escape) tmux send-keys -t "${picker_pane}" Escape ;;
    esac
    for attempt in {1..100}; do
      [[ -f "${FIXTURE_DIRECTORY}/keys-${key_sequence}-done" ]] && break
      sleep 0.02
    done
    [[ -f "${FIXTURE_DIRECTORY}/keys-${key_sequence}-done" ]] || fail "${key_sequence}: picker did not finish"
    assert_picker_cursor "${picker_pane}" 1
    if [[ "${key_sequence}" == *quit || "${key_sequence}" == *escape ]]; then
      [[ ! -s "${FIXTURE_DIRECTORY}/keys-${key_sequence}-paste" ]] || fail "${key_sequence}: quit pasted text"
    else
      cmp -s "${expected_path}" "${FIXTURE_DIRECTORY}/keys-${key_sequence}-paste" || fail "${key_sequence}: selected wrong entry"
    fi
    tmux kill-pane -t "${picker_pane}"
    tmux kill-pane -t "${receiver_pane}"
    pass "real fzf ${key_sequence}: navigation/search/quit and rendered palette"
  done
else
  printf '[history-test] SKIP: real keystroke checks require fzf\n'
fi

# Validate the actual CopyQ JavaScript API in an isolated session when a desktop
# is available. This does not change the user's clipboard or CopyQ history.
copyq_binary="${PROJECT_DIRECTORY}/plugins/clipboard-runtime/usr/bin/copyq"
if [[ -x "${copyq_binary}" && -n "${DISPLAY:-}" ]]; then
  export COPYQ_SETTINGS_PATH="${FIXTURE_DIRECTORY}/copyq-config" QT_QPA_PLATFORM=xcb
  "${copyq_binary}" --session beck-history --start-server count >/dev/null
  sample_base64="$(base64 -w0 "${FIXTURE_DIRECTORY}/sample")"
  "${copyq_binary}" --session beck-history -- eval \
    'tab("fixture"); add(fromBase64(arguments[1]));' "${sample_base64}"
  "${copyq_binary}" --session beck-history -- eval '
    tab("fixture");
    var data = read("text/plain", 0);
    var preview = str(data).replace(/[\x00-\x1f\x7f-\x9f]/g, " ").slice(0, 200);
    print(toBase64(data) + "\t" + preview + "\n");
  ' >"${FIXTURE_DIRECTORY}/real-snapshot"
  "${copyq_binary}" --session beck-history exit
  IFS=$'\t' read -r actual_base64 actual_preview <"${FIXTURE_DIRECTORY}/real-snapshot"
  [[ "${actual_base64}" == "${sample_base64}" ]] || fail 'real CopyQ changed snapshot bytes'
  [[ "${actual_preview}" != *$'\n'* && "${actual_preview}" == *'$(touch never-run)'* ]] || fail 'real CopyQ preview differs'
  pass 'real CopyQ snapshot API preserves bytes in isolated session'
else
  printf '[history-test] SKIP: real CopyQ API test requires the optional local runtime\n'
fi
