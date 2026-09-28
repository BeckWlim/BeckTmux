#!/usr/bin/env bash

# Smoke-test the checked-in tmux configuration without touching a live server.

set -Eeuo pipefail

readonly TESTS_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIRECTORY="$(cd -- "${TESTS_DIRECTORY}/.." && pwd)"
readonly TMUX_CONFIG_PATH="${PROJECT_DIRECTORY}/tmux.conf"
readonly SETUP_SCRIPT_PATH="${PROJECT_DIRECTORY}/scripts/setup.sh"
readonly MIGRATION_SCRIPT_PATH="${PROJECT_DIRECTORY}/scripts/migrate-tmux.sh"
readonly THEME_SCRIPT_PATH="${PROJECT_DIRECTORY}/scripts/theme.sh"

temporary_directory=""
tmux_socket_path=""
passed_assertions=0

fail() {
  printf '[test] FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  passed_assertions=$((passed_assertions + 1))
  printf '[test] ok: %s\n' "$1"
}

assert_equal() {
  local description="$1"
  local expected_value="$2"
  local actual_value="$3"

  [[ "${actual_value}" == "${expected_value}" ]] || \
    fail "${description}: expected '${expected_value}', got '${actual_value}'"
  pass "${description}"
}

assert_contains() {
  local description="$1"
  local expected_fragment="$2"
  local actual_value="$3"

  [[ "${actual_value}" == *"${expected_fragment}"* ]] || \
    fail "${description}: expected output to contain '${expected_fragment}'"
  pass "${description}"
}

cleanup() {
  if [[ -n "${tmux_socket_path}" ]]; then
    tmux -S "${tmux_socket_path}" kill-server >/dev/null 2>&1 || true
  fi
  if [[ -n "${temporary_directory}" && -d "${temporary_directory}" ]]; then
    rm -f -- "${temporary_directory}/clip.exe" "${temporary_directory}/wl-copy" "${temporary_directory}/server.sock" \
      "${temporary_directory}/clipboard.bin" "${temporary_directory}/clipboard.bin.pending"
    rmdir -- "${temporary_directory}" 2>/dev/null || true
  fi
}

require_command() {
  local command_name="$1"

  command -v "${command_name}" >/dev/null 2>&1 || \
    fail "required command is unavailable: ${command_name}"
}

check_shell_scripts() {
  local shell_script_path

  for shell_script_path in "${PROJECT_DIRECTORY}"/scripts/*.sh "${TESTS_DIRECTORY}"/*.sh; do
    bash -n "${shell_script_path}"
    [[ -x "${shell_script_path}" ]] || fail "script is not executable: ${shell_script_path}"
  done
  "${SETUP_SCRIPT_PATH}" --help >/dev/null
  "${MIGRATION_SCRIPT_PATH}" --help >/dev/null
  "${THEME_SCRIPT_PATH}" --help >/dev/null
  "${TESTS_DIRECTORY}/setup.sh"
  pass 'shell scripts parse, are executable, and expose help without side effects'
}

start_isolated_server() {
  temporary_directory="$(mktemp -d /tmp/beck-tmux-tests.XXXXXXXX)"
  tmux_socket_path="${temporary_directory}/server.sock"
  cat >"${temporary_directory}/clip.exe" <<'CLIPBOARD_STUB'
#!/bin/sh
cat >"${BECK_TMUX_TEST_CLIPBOARD_PATH}.pending"
mv "${BECK_TMUX_TEST_CLIPBOARD_PATH}.pending" "${BECK_TMUX_TEST_CLIPBOARD_PATH}"
CLIPBOARD_STUB
  chmod +x "${temporary_directory}/clip.exe"
  cat >"${temporary_directory}/wl-copy" <<'WAYLAND_STUB'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = --type ] && [ "$2" = text/plain ] || exit 2
cat >"${BECK_TMUX_TEST_CLIPBOARD_PATH}.pending"
mv "${BECK_TMUX_TEST_CLIPBOARD_PATH}.pending" "${BECK_TMUX_TEST_CLIPBOARD_PATH}"
WAYLAND_STUB
  chmod +x "${temporary_directory}/wl-copy"
  env -u TMUX BECK_TMUX_TEST_CLIPBOARD_PATH="${temporary_directory}/clipboard.bin" \
    WAYLAND_DISPLAY=beck-test PATH="${temporary_directory}:${PATH}" \
    tmux -S "${tmux_socket_path}" -f "${TMUX_CONFIG_PATH}" \
    new-session -d -s config-test
  pass 'tmux.conf starts an isolated server'
}

global_option() {
  tmux -S "${tmux_socket_path}" show-options -gv "$1"
}

window_option() {
  tmux -S "${tmux_socket_path}" show-window-options -gv "$1"
}

binding() {
  local key_table="$1"
  local key_name="$2"

  tmux -S "${tmux_socket_path}" list-keys -T "${key_table}" "${key_name}"
}

check_options() {
  local status_left_value
  local status_right_value

  assert_equal 'default terminal supports 256 colours' 'tmux-256color' \
    "$(global_option default-terminal)"
  assert_equal 'prefix is C-s' 'C-s' "$(global_option prefix)"
  assert_equal 'terminal focus events are enabled' 'on' "$(global_option focus-events)"
  assert_equal 'mouse support is enabled' 'on' "$(global_option mouse)"
  assert_equal 'status keys use vi mode' 'vi' "$(global_option status-keys)"
  assert_equal 'copy mode uses vi keys' 'vi' "$(window_option mode-keys)"
  assert_equal 'window numbering starts at one' '1' "$(global_option base-index)"
  assert_equal 'pane numbering starts at one' '1' "$(window_option pane-base-index)"

  status_left_value="$(global_option status-left)"
  status_right_value="$(global_option status-right)"
  assert_contains 'left status exposes visual mode' '[ VISUAL ]' "${status_left_value}"
  assert_contains 'left status exposes command mode' '[ COMMAND ]' "${status_left_value}"
  assert_contains 'left status exposes input mode' '[ INPUT ]' "${status_left_value}"
  assert_contains 'right status exposes focused state' '[ FOCUSED ]' "${status_right_value}"
}

check_bindings() {
  assert_contains 'double prefix sends C-s to the application' 'send-prefix' \
    "$(binding prefix C-s)"
  assert_equal 'secondary prefix is disabled' 'None' "$(global_option prefix2)"
  assert_equal 'old C-b prefix binding is removed' '' \
    "$(binding prefix C-b 2>/dev/null || true)"
  assert_contains 'prefix j enters copy mode' 'copy-mode' "$(binding prefix j)"
  assert_contains 'prefix h creates a horizontal split' 'split-window -h' \
    "$(binding prefix h)"
  assert_contains 'resize j moves the divider left' 'resize-pane -L 5' \
    "$(binding resize j)"
  assert_contains 'copy-mode v starts a selection' 'begin-selection' \
    "$(binding copy-mode-vi v)"
  assert_contains 'copy-mode i returns to input' 'cancel' \
    "$(binding copy-mode-vi i)"
  assert_contains 'input C-h sends Left' 'send-keys Left' "$(binding root C-h)"
  assert_contains 'input C-j sends Down' 'send-keys Down' "$(binding root C-j)"
  assert_contains 'input C-k sends Up' 'send-keys Up' "$(binding root C-k)"
  assert_equal 'input C-p retains native application behavior' '' \
    "$(binding root C-p 2>/dev/null || true)"
  tmux -S "${tmux_socket_path}" bind-key -n C-p send-keys stale-paste
  tmux -S "${tmux_socket_path}" source-file "${TMUX_CONFIG_PATH}"
  assert_equal 'reload removes the legacy C-p paste binding' '' \
    "$(binding root C-p 2>/dev/null || true)"
  assert_contains 'input C-l sends Right' 'send-keys Right' "$(binding root C-l)"
  assert_equal 'input C-d retains native application behavior' '' \
    "$(binding root C-d 2>/dev/null || true)"
  assert_contains 'copy-mode y prefers the native Wayland clipboard' 'wl-copy --type text/plain' \
    "$(binding copy-mode-vi y)"
}

check_clipboard() {
  local provider_name="$1"
  local clipboard_encoding="$2"
  local clipboard_pane_id
  local copy_key
  local sample_text
  local copied_text
  local attempt
  local cursor_before

  for copy_key in y C-c Enter; do
    sample_text="clipboard-${copy_key}: 中文 café 😀"
    clipboard_pane_id="$(tmux -S "${tmux_socket_path}" new-window -d -P -F '#{pane_id}' \
      bash -c 'printf "%s\n" "$1"; exec sleep 120' clipboard-test "${sample_text}")"
    # Wait for the sample to render before entering copy mode.
    for attempt in {1..100}; do
      if [[ "$(tmux -S "${tmux_socket_path}" capture-pane -p -t "${clipboard_pane_id}")" == *"${sample_text}"* ]]; then
        break
      fi
      sleep 0.05
    done
    tmux -S "${tmux_socket_path}" copy-mode -t "${clipboard_pane_id}"
    tmux -S "${tmux_socket_path}" send-keys -t "${clipboard_pane_id}" -X history-top
    tmux -S "${tmux_socket_path}" send-keys -t "${clipboard_pane_id}" 0 v '$'
    assert_equal "${copy_key}: visual selection is active" '1' \
      "$(tmux -S "${tmux_socket_path}" display-message -p -t "${clipboard_pane_id}" '#{selection_present}')"
    cursor_before="$(tmux -S "${tmux_socket_path}" display-message -p -t "${clipboard_pane_id}" '#{copy_cursor_x}:#{copy_cursor_y}')"
    tmux -S "${tmux_socket_path}" send-keys -t "${clipboard_pane_id}" "${copy_key}"
    copied_text=""
    for attempt in {1..100}; do
      if [[ -f "${temporary_directory}/clipboard.bin" ]]; then
        copied_text="$(iconv -f "${clipboard_encoding}" -t UTF-8 "${temporary_directory}/clipboard.bin")"
        [[ "${copied_text}" == "${sample_text}" ]] && break
      fi
      sleep 0.05
    done
    assert_equal "${copy_key}: ${provider_name} receives lossless Unicode" "${sample_text}" "${copied_text}"
    assert_equal "${copy_key}: tmux paste buffer retains UTF-8" "${sample_text}" \
      "$(tmux -S "${tmux_socket_path}" save-buffer -)"
    assert_equal "${copy_key}: copy clears selection and keeps command mode" 'copy-mode:0' \
      "$(tmux -S "${tmux_socket_path}" display-message -p -t "${clipboard_pane_id}" '#{pane_mode}:#{selection_present}')"
    assert_equal "${copy_key}: copy preserves the cursor" "${cursor_before}" \
      "$(tmux -S "${tmux_socket_path}" display-message -p -t "${clipboard_pane_id}" '#{copy_cursor_x}:#{copy_cursor_y}')"
    tmux -S "${tmux_socket_path}" kill-pane -t "${clipboard_pane_id}"
  done
}

check_clipboard_fallback() {
  tmux -S "${tmux_socket_path}" set-environment -g WAYLAND_DISPLAY ''
  tmux -S "${tmux_socket_path}" source-file "${TMUX_CONFIG_PATH}"
  assert_contains 'without Wayland, copy uses the Windows bridge' 'iconv -f UTF-8 -t UTF-16LE | clip.exe' \
    "$(binding copy-mode-vi y)"
  # The previous provider wrote UTF-8; clear its artifact before decoding UTF-16LE.
  rm -f -- "${temporary_directory}/clipboard.bin"
  check_clipboard 'Windows bridge' UTF-16LE
}

check_application_theme() {
  local application_pane_id
  local application_owner_pid
  local shell_pane_id
  local second_application_pane_id
  local second_application_owner_pid
  local malformed_entry
  local original_window_style
  original_window_style="$(global_option window-style)"
  application_pane_id="$(tmux -S "${tmux_socket_path}" display-message -p '#{pane_id}')"
  tmux -S "${tmux_socket_path}" respawn-pane -k -t "${application_pane_id}" sleep 120
  application_owner_pid="$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{pane_pid}')"
  shell_pane_id="$(tmux -S "${tmux_socket_path}" split-window -d -P -F '#{pane_id}')"
  second_application_pane_id="$(tmux -S "${tmux_socket_path}" split-window -d -P -F '#{pane_id}' sleep 120)"
  second_application_owner_pid="$(tmux -S "${tmux_socket_path}" display-message -p -t "${second_application_pane_id}" '#{pane_pid}')"
  assert_equal 'renderer starts with the default palette' '#272822|#f8f8f2' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{pane_bg}|#{pane_fg}')"

  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${application_pane_id}" \
    "${THEME_SCRIPT_PATH}" set --owner "${application_owner_pid}" 'bg=#fafaf7' 'fg=#242424' 'green=#3d6815'
  assert_equal 'application publishes pane colours' '#fafaf7|#242424|#3d6815' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{E:@beck_pane_bg}|#{E:@beck_pane_fg}|#{E:@beck_pane_green}')"
  assert_equal 'publication refreshes cached renderer colours' '#fafaf7|#242424' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{pane_bg}|#{pane_fg}')"
  assert_equal 'application preserves tmux default night colour' '#272822' "$(global_option @beck_default_bg)"
  assert_equal 'omitted palette roles inherit tmux defaults' '#666666' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{E:@beck_pane_border}')"
  assert_equal 'status style resolves application colours' 'fg=#a6a69c,bg=#fafaf7' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{E:status-style}')"

  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${second_application_pane_id}" \
    "${THEME_SCRIPT_PATH}" set --owner "${second_application_owner_pid}" 'bg=#112233'
  tmux -S "${tmux_socket_path}" select-pane -t "${second_application_pane_id}"
  assert_equal 'focus follows a second application palette' '#112233' \
    "$(tmux -S "${tmux_socket_path}" display-message -p '#{E:@beck_pane_bg}')"
  assert_equal 'unselected pane border uses the focused pane UI palette' 'fg=#666666,bg=#112233' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{E:pane-border-style}')"
  tmux -S "${tmux_socket_path}" select-pane -t "${shell_pane_id}"
  assert_equal 'shell pane retains the night palette' '#272822' \
    "$(tmux -S "${tmux_socket_path}" display-message -p '#{E:@beck_pane_bg}')"
  assert_equal 'pane switch restores default shared UI without erasing cached application colours' '#272822|#fafaf7' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{E:@beck_ui_bg}|#{@beck_palette_bg}')"

  for malformed_entry in 'bg=red' 'bg=#123456;display-message bad' 'unknown=#123456'; do
    if env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${application_pane_id}" \
        "${THEME_SCRIPT_PATH}" set --owner "${application_owner_pid}" 'fg=#ffffff' "${malformed_entry}" >/dev/null 2>&1; then
      fail 'malformed palette was accepted'
    fi
  done
  assert_equal 'invalid palettes leave all existing colours intact' '#fafaf7|#242424' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{E:@beck_pane_bg}|#{E:@beck_pane_fg}')"
  if env -u TMUX -u TMUX_PANE "${THEME_SCRIPT_PATH}" reset >/dev/null 2>&1; then
    fail 'theme hook accepted missing pane context'
  fi
  pass 'theme hook refuses missing pane context'

  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${application_pane_id}" \
    "${THEME_SCRIPT_PATH}" set --owner "${application_owner_pid}" 'bg=#eeeeee'
  assert_equal 'replacement drops roles from the previous palette' '#eeeeee|#f8f8f2' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{E:@beck_pane_bg}|#{E:@beck_pane_fg}')"
  assert_equal 'replacement refreshes inactive renderer colours and omitted roles' '#eeeeee|#f8f8f2' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{pane_bg}|#{pane_fg}')"
  tmux -S "${tmux_socket_path}" source-file "${TMUX_CONFIG_PATH}"
  assert_equal 'config reload preserves application overrides' '#eeeeee' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{E:@beck_pane_bg}')"
  # pane_bg/pane_fg read the renderer's cached colours, unlike E: formats.
  # Prime that cache while light, then reset without reloading the config.
  assert_equal 'renderer caches the light application palette' '#eeeeee|#f8f8f2' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{pane_bg}|#{pane_fg}')"
  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${application_pane_id}" "${THEME_SCRIPT_PATH}" reset --owner "${application_owner_pid}"
  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${application_pane_id}" "${THEME_SCRIPT_PATH}" reset --owner "${application_owner_pid}"
  assert_equal 'reset is repeatable and restores inherited night colours' '#272822|#f8f8f2' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{E:@beck_pane_bg}|#{E:@beck_pane_fg}')"
  assert_equal 'reset restores the renderer as well as palette formats' '#272822|#f8f8f2' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${application_pane_id}" '#{pane_bg}|#{pane_fg}')"
  assert_equal 'reset leaves other applications alone' '#112233' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${second_application_pane_id}" '#{E:@beck_pane_bg}')"
  assert_equal 'cache refresh preserves the global style format exactly' "${original_window_style}" \
    "$(global_option window-style)"
  assert_equal 'cache refresh preserves pane style inheritance' '' \
    "$(tmux -S "${tmux_socket_path}" show-options -pqv -t "${application_pane_id}" window-style)"
}

wait_for_pane_format() {
  local pane_id="$1"
  local pane_format="$2"
  local expected_value="$3"
  local attempt actual_value
  for attempt in {1..50}; do
    actual_value="$(tmux -S "${tmux_socket_path}" display-message -p -t "${pane_id}" "${pane_format}")"
    [[ "${actual_value}" == "${expected_value}" ]] && return 0
    sleep 0.1
  done
  fail "pane ${pane_id} did not reach '${expected_value}': got '${actual_value}'"
}

check_window_palette_cache() {
  local light_pane_id dark_pane_id plain_pane_id other_session_pane_id
  local light_owner_pid dark_owner_pid
  local light_token dark_token
  local light_window_index dark_window_index
  local rendered_windows
  light_pane_id="$(tmux -S "${tmux_socket_path}" new-window -d -n palette-light -P -F '#{pane_id}' sleep 120)"
  dark_pane_id="$(tmux -S "${tmux_socket_path}" new-window -d -n palette-dark -P -F '#{pane_id}' sleep 120)"
  plain_pane_id="$(tmux -S "${tmux_socket_path}" new-window -d -n palette-default -P -F '#{pane_id}' sleep 120)"
  light_owner_pid="$(tmux -S "${tmux_socket_path}" display-message -p -t "${light_pane_id}" '#{pane_pid}')"
  dark_owner_pid="$(tmux -S "${tmux_socket_path}" display-message -p -t "${dark_pane_id}" '#{pane_pid}')"
  light_window_index="$(tmux -S "${tmux_socket_path}" display-message -p -t "${light_pane_id}" '#{window_index}')"
  dark_window_index="$(tmux -S "${tmux_socket_path}" display-message -p -t "${dark_pane_id}" '#{window_index}')"
  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${light_pane_id}" \
    "${THEME_SCRIPT_PATH}" set --owner "${light_owner_pid}" 'bg=#fafaf7' 'fg=#242424' \
    'muted=#666660' 'green=#3d6815' 'cursor=#e5e5e0'
  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${dark_pane_id}" \
    "${THEME_SCRIPT_PATH}" set --owner "${dark_owner_pid}" 'bg=#101010' 'fg=#eeeeee' \
    'window_active_fg=#aabbcc' 'window_active_bg=#303030' \
    'window_inactive_fg=#888899' 'window_inactive_bg=#121212'
  light_token="$(tmux -S "${tmux_socket_path}" show-options -pqv -t "${light_pane_id}" @beck_theme_token)"
  dark_token="$(tmux -S "${tmux_socket_path}" show-options -pqv -t "${dark_pane_id}" @beck_theme_token)"
  assert_equal 'applications store palettes in their own namespace' '#fafaf7' \
    "$(tmux -S "${tmux_socket_path}" show-options -pqv -t "${light_pane_id}" @beck_palette_bg)"
  assert_equal 'applications leave global default namespace unchanged' '#272822' "$(global_option @beck_default_bg)"

  tmux -S "${tmux_socket_path}" select-window -t "${light_pane_id}"
  rendered_windows="$(tmux -S "${tmux_socket_path}" display-message -p -t "${light_pane_id}" '#{W:#{E:window-status-format},#{E:window-status-current-format}}')"
  assert_contains 'unselected window tag uses the focused light palette' \
    "#[fg=#666660,bg=#fafaf7,nobold,noreverse] ${dark_window_index}  palette-dark " "${rendered_windows}"
  assert_contains 'selected window tag derives its colours from the same palette' \
    "#[fg=#3d6815,bg=#e5e5e0,bold,noreverse] ${light_window_index}  palette-light " "${rendered_windows}"
  assert_equal 'inactive-window context resolves chrome from the session current window' '#fafaf7' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${dark_pane_id}" '#{E:@beck_ui_bg}')"
  assert_equal 'inactive window retains its own content colours' 'fg=#eeeeee,bg=#101010' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${dark_pane_id}" '#{E:window-style}')"

  tmux -S "${tmux_socket_path}" select-window -t "${dark_pane_id}"
  rendered_windows="$(tmux -S "${tmux_socket_path}" display-message -p -t "${dark_pane_id}" '#{W:#{E:window-status-format},#{E:window-status-current-format}}')"
  assert_contains 'switch immediately uses cached inactive-tag colours' \
    "#[fg=#888899,bg=#121212,nobold,noreverse] ${light_window_index}  palette-light " "${rendered_windows}"
  assert_contains 'switch immediately uses cached selected-tag colours' \
    "#[fg=#aabbcc,bg=#303030,bold,noreverse] ${dark_window_index}  palette-dark " "${rendered_windows}"
  sleep 1.2
  assert_equal 'window focus changes do not revoke the hidden application palette' "${light_token}" \
    "$(tmux -S "${tmux_socket_path}" show-options -pqv -t "${light_pane_id}" @beck_theme_token)"
  tmux -S "${tmux_socket_path}" select-window -t "${light_pane_id}"
  assert_equal 'switching back restores the cached palette without republishing' '#fafaf7' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${light_pane_id}" '#{E:@beck_ui_bg}')"
  assert_equal 'switching windows does not republish the other application palette' "${dark_token}" \
    "$(tmux -S "${tmux_socket_path}" show-options -pqv -t "${dark_pane_id}" @beck_theme_token)"

  other_session_pane_id="$(tmux -S "${tmux_socket_path}" new-session -d -s palette-other -P -F '#{pane_id}' sleep 120)"
  assert_equal 'another session independently resolves its default palette' '#272822' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${other_session_pane_id}" '#{E:@beck_ui_bg}')"
  assert_equal 'another session cannot change this session palette' '#fafaf7' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${light_pane_id}" '#{E:@beck_ui_bg}')"

  # Replacing a palette invalidates derived tag roles, without keeping old
  # explicit overrides or requiring the inactive application to gain focus.
  # Keep format queries targeted: after creating another detached session,
  # an untargeted command may inspect that session instead of config-test.
  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${dark_pane_id}" \
    "${THEME_SCRIPT_PATH}" set --owner "${dark_owner_pid}" 'bg=#202020' 'muted=#bbbbbb'
  tmux -S "${tmux_socket_path}" select-window -t "${dark_pane_id}"
  assert_equal 'background publication replaces cache and drops old explicit tag colours' '#bbbbbb|#202020' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${dark_pane_id}" '#{E:@beck_ui_window_inactive_fg}|#{E:@beck_ui_window_inactive_bg}')"
  tmux -S "${tmux_socket_path}" select-window -t "${plain_pane_id}"
  assert_equal 'an unpublished window restores default chrome including inactive tags' '#272822|#a6a69c|#272822' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${plain_pane_id}" '#{E:@beck_ui_bg}|#{E:@beck_ui_window_inactive_fg}|#{E:@beck_ui_window_inactive_bg}')"
  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${light_pane_id}" "${THEME_SCRIPT_PATH}" reset --force
  tmux -S "${tmux_socket_path}" select-window -t "${light_pane_id}"
  assert_equal 'cleared cache cannot resurrect an old palette on window selection' '#272822|' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${light_pane_id}" '#{E:@beck_ui_bg}|#{@beck_palette_bg}')"
}

check_theme_recovery() {
  local recovery_pane_id
  local owner_pid
  local original_token
  local original_identity
  local pane_tty
  local replacement_owner_pid
  # A real interactive shell provides job control: Ctrl-Z returns ownership
  # of the same terminal to the shell without destroying the application.
  recovery_pane_id="$(tmux -S "${tmux_socket_path}" new-window -d -P -F '#{pane_id}' bash --noprofile --norc -i)"
  tmux -S "${tmux_socket_path}" send-keys -t "${recovery_pane_id}" 'sleep 120' Enter
  wait_for_pane_format "${recovery_pane_id}" '#{pane_current_command}' sleep
  pane_tty="$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{pane_tty}')"
  # sleep is the foreground job's group leader in this interactive shell.
  local pane_shell_pid
  local owner_group_output
  pane_shell_pid="$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{pane_pid}')"
  owner_group_output="$(ps -p "${pane_shell_pid}" -o tpgid=)"
  owner_pid="${owner_group_output//[[:space:]]/}"
  # Publisher and tmux-owned watcher may have different wall-clock settings.
  # Process identity must remain stable regardless of ps lstart formatting.
  env TZ=UTC12 TMUX="${tmux_socket_path},0,0" TMUX_PANE="${recovery_pane_id}" \
    "${THEME_SCRIPT_PATH}" set --owner "${owner_pid}" 'bg=#eeeeee'
  original_token="$(tmux -S "${tmux_socket_path}" show-options -pqv -t "${recovery_pane_id}" @beck_theme_token)"
  original_identity="$(tmux -S "${tmux_socket_path}" show-options -pqv -t "${recovery_pane_id}" @beck_theme_owner)"
  assert_equal 'renderer caches light colours before watcher recovery' '#eeeeee' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{pane_bg}')"
  sleep 1.2
  assert_equal 'live foreground publisher retains colours across watchdog checks' '#eeeeee' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{E:@beck_pane_bg}')"
  if [[ -r /proc/self/stat ]]; then
    assert_contains 'Linux owner identity uses stable boot-relative ticks' ':ticks:' "${original_identity}"
  fi

  tmux -S "${tmux_socket_path}" send-keys -t "${recovery_pane_id}" C-z
  wait_for_pane_format "${recovery_pane_id}" '#{pane_current_command}' bash
  wait_for_pane_format "${recovery_pane_id}" '#{E:@beck_pane_bg}|#{@beck_theme_token}' '#272822|'
  pass 'suspended application restores defaults without application cleanup'
  assert_equal 'watcher recovery clears the renderer light background' '#272822' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{pane_bg}')"
  if env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${recovery_pane_id}" \
      "${THEME_SCRIPT_PATH}" set --owner "${owner_pid}" 'bg=#eeeeee' >/dev/null 2>&1; then
    fail 'suspended owner was allowed to republish'
  fi
  pass 'background or suspended owners cannot take over the theme'

  tmux -S "${tmux_socket_path}" send-keys -t "${recovery_pane_id}" fg Enter
  wait_for_pane_format "${recovery_pane_id}" '#{pane_current_command}' sleep
  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${recovery_pane_id}" \
    "${THEME_SCRIPT_PATH}" set --owner "${owner_pid}" 'bg=#dddddd'
  assert_equal 'resumed application restores renderer colours' '#dddddd' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{pane_bg}')"
  # A stale watcher must not clear a newer publication, even if its process
  # identity check would fail. This exercises the real internal entry point.
  "${THEME_SCRIPT_PATH}" _watch "${tmux_socket_path}" "${recovery_pane_id}" \
    "${owner_pid}" "${pane_tty}" invalid-identity "${original_token}"
  assert_equal 'old watcher cannot clear a newer publication' '#dddddd' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{E:@beck_pane_bg}')"

  kill -KILL -- "-${owner_pid}"
  wait_for_pane_format "${recovery_pane_id}" '#{pane_current_command}' bash
  wait_for_pane_format "${recovery_pane_id}" '#{E:@beck_pane_bg}|#{@beck_theme_owner}' '#272822|'
  pass 'killing the entire application job restores defaults without cleanup'
  assert_equal 'killed application leaves the renderer at night defaults' '#272822' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{pane_bg}')"

  tmux -S "${tmux_socket_path}" send-keys -t "${recovery_pane_id}" 'sleep 120' Enter
  wait_for_pane_format "${recovery_pane_id}" '#{pane_current_command}' sleep
  local replacement_group_output
  replacement_group_output="$(ps -p "${pane_shell_pid}" -o tpgid=)"
  replacement_owner_pid="${replacement_group_output//[[:space:]]/}"
  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${recovery_pane_id}" \
    "${THEME_SCRIPT_PATH}" set --owner "${replacement_owner_pid}" 'bg=#cccccc'
  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${recovery_pane_id}" \
    "${THEME_SCRIPT_PATH}" reset --owner "${owner_pid}"
  assert_equal 'old publisher cannot reset a new publisher with the same command name' '#cccccc' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{E:@beck_pane_bg}')"
  # A mismatched birth time also expires a claim even while its PID is live.
  local replacement_token
  replacement_token="$(tmux -S "${tmux_socket_path}" show-options -pqv -t "${recovery_pane_id}" @beck_theme_token)"
  "${THEME_SCRIPT_PATH}" _watch "${tmux_socket_path}" "${recovery_pane_id}" \
    "${replacement_owner_pid}" "${pane_tty}" "${original_identity}" "${replacement_token}"
  assert_equal 'process identity mismatch expires a stale claim' '#272822' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{E:@beck_pane_bg}')"
  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${recovery_pane_id}" \
    "${THEME_SCRIPT_PATH}" set --owner "${replacement_owner_pid}" 'bg=#bbbbbb'
  assert_equal 'renderer caches light colours before manual recovery' '#bbbbbb' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{pane_bg}')"
  env TMUX="${tmux_socket_path},0,0" TMUX_PANE="${recovery_pane_id}" "${THEME_SCRIPT_PATH}" reset --force
  assert_equal 'manual force reset restores defaults regardless of owner' '#272822' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{E:@beck_pane_bg}')"
  assert_equal 'manual force reset restores renderer defaults' '#272822' \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${recovery_pane_id}" '#{pane_bg}')"

  local handoff_pane_id
  local handoff_owner_pid
  handoff_pane_id="$(tmux -S "${tmux_socket_path}" new-window -d -P -F '#{pane_id}' \
    bash -c '"$1" set "bg=#aaaaaa" || exit; IFS= read -r handoff; exec sleep 120' \
    theme-test "${THEME_SCRIPT_PATH}")"
  wait_for_pane_format "${handoff_pane_id}" '#{E:@beck_pane_bg}' '#aaaaaa'
  handoff_owner_pid="$(tmux -S "${tmux_socket_path}" display-message -p -t "${handoff_pane_id}" '#{pane_pid}')"
  assert_contains 'direct application call uses its parent process as owner' "${handoff_owner_pid}:" \
    "$(tmux -S "${tmux_socket_path}" show-options -pqv -t "${handoff_pane_id}" @beck_theme_owner)"
  tmux -S "${tmux_socket_path}" send-keys -t "${handoff_pane_id}" Enter
  wait_for_pane_format "${handoff_pane_id}" '#{pane_current_command}' sleep
  wait_for_pane_format "${handoff_pane_id}" '#{E:@beck_pane_bg}' '#272822'
  assert_equal 'exec handoff restores defaults even when the owner PID remains alive' "${handoff_owner_pid}" \
    "$(tmux -S "${tmux_socket_path}" display-message -p -t "${handoff_pane_id}" '#{pane_pid}')"
}

main() {
  trap cleanup EXIT
  require_command bash
  require_command tmux
  require_command iconv
  check_shell_scripts
  start_isolated_server
  check_options
  check_bindings
  check_clipboard Wayland UTF-8
  check_clipboard_fallback
  check_application_theme
  check_theme_recovery
  check_window_palette_cache
  printf '[test] PASS: %d assertions\n' "${passed_assertions}"
}

main "$@"
