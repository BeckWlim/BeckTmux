#!/usr/bin/env bash

# Smoke-test the checked-in tmux configuration without touching a live server.

set -Eeuo pipefail

readonly TESTS_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIRECTORY="$(cd -- "${TESTS_DIRECTORY}/.." && pwd)"
readonly TMUX_CONFIG_PATH="${PROJECT_DIRECTORY}/tmux.conf"
readonly SETUP_SCRIPT_PATH="${PROJECT_DIRECTORY}/scripts/setup.sh"
readonly MIGRATION_SCRIPT_PATH="${PROJECT_DIRECTORY}/scripts/migrate-tmux.sh"

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
    rm -f -- "${temporary_directory}/clip.exe" "${temporary_directory}/server.sock"
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
  pass 'shell scripts parse, are executable, and expose help without side effects'
}

start_isolated_server() {
  temporary_directory="$(mktemp -d /tmp/beck-tmux-tests.XXXXXXXX)"
  tmux_socket_path="${temporary_directory}/server.sock"
  ln -s "$(command -v true)" "${temporary_directory}/clip.exe"
  env -u TMUX PATH="${temporary_directory}:${PATH}" \
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
  assert_equal 'prefix is C-a' 'C-a' "$(global_option prefix)"
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
  assert_contains 'prefix j enters copy mode' 'copy-mode' "$(binding prefix j)"
  assert_contains 'prefix h creates a horizontal split' 'split-window -h' \
    "$(binding prefix h)"
  assert_contains 'resize j moves the divider left' 'resize-pane -L 5' \
    "$(binding resize j)"
  assert_contains 'copy-mode v starts a selection' 'begin-selection' \
    "$(binding copy-mode-vi v)"
  assert_contains 'copy-mode i returns to input' 'cancel' \
    "$(binding copy-mode-vi i)"
  assert_contains 'copy-mode y uses the external clipboard bridge' 'copy-pipe -C clip.exe' \
    "$(binding copy-mode-vi y)"
}

main() {
  trap cleanup EXIT
  require_command bash
  require_command tmux
  check_shell_scripts
  start_isolated_server
  check_options
  check_bindings
  printf '[test] PASS: %d assertions\n' "${passed_assertions}"
}

main "$@"
