#!/usr/bin/env bash

# Application-owned palette overrides for the calling tmux pane.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: theme.sh set ROLE=#RRGGBB [ROLE=#RRGGBB ...]
       theme.sh reset
       theme.sh reset --force

set/reset accept --owner PID before palette entries (default: parent process).
Use --owner when a shell wrapper sits between the application and this hook.

Set replaces this pane's palette; omitted roles use tmux's defaults.
Reset removes this pane's overrides. Neither command changes global defaults.
Overrides expire when the owner exits or loses the foreground terminal.
An old owner's reset cannot clear a newer owner's palette; --force resets any owner.
Roles: bg surface cursor border fg muted green cyan yellow purple red
       window_active_fg window_active_bg window_inactive_fg window_inactive_bg
Applications publish @beck_palette_*; tmux owns defaults and UI resolution.
Requires TMUX and TMUX_PANE inherited from the application's pane.
EOF
}

fail() {
  printf '[tmux-theme] %s\n' "$*" >&2
  exit 2
}

readonly PALETTE_ROLES=(bg surface cursor border fg muted green cyan yellow purple red
  window_active_fg window_active_bg window_inactive_fg window_inactive_bg)

# Birth identity guards against PID reuse; the command detects exec handoffs.
# On Linux, ps lstart converts boot-relative ticks to wall time and can drift
# when the system clock/boot-time estimate changes (including under WSL).
owner_identity() {
  local owner_pid="$1"
  local pane_tty="$2"
  local process_description
  local owner_tty owner_group_id foreground_group_id owner_state owner_command
  local owner_birth process_stat
  local -a process_fields
  process_description="$(LC_ALL=C ps -p "${owner_pid}" -o tty= -o pgid= -o tpgid= -o stat= -o comm=)" || return 1
  read -r owner_tty owner_group_id foreground_group_id owner_state owner_command <<<"${process_description}"
  [[ "${owner_tty}" == "${pane_tty#/dev/}" && "${owner_group_id}" == "${foreground_group_id}" &&
      "${foreground_group_id}" != -1 && "${owner_state}" != *[TXZ]* && -n "${owner_command}" ]] || return 1
  if [[ -r /proc/self/stat ]]; then
    IFS= read -r process_stat < "/proc/${owner_pid}/stat" || return 1
    # comm (field 2) may contain spaces or parentheses; strip through its
    # final closing parenthesis. The remaining array starts at field 3.
    read -r -a process_fields <<<"${process_stat##*) }"
    owner_birth="${process_fields[19]:-}"
    [[ "${owner_birth}" =~ ^[0-9]+$ ]] || return 1
    owner_birth="ticks:${owner_birth}"
  else
    owner_birth="$(LC_ALL=C TZ=UTC0 ps -p "${owner_pid}" -o lstart=)" || return 1
    [[ -n "${owner_birth//[[:space:]]/}" ]] || return 1
  fi
  printf '%s:%s:%s' "${owner_pid}" "${owner_birth}" "${owner_command}"
}

clear_commands() {
  local pane_id="$1"
  local reset_role
  for reset_role in "${PALETTE_ROLES[@]}"; do
    printf 'set-option -pu -t %s @beck_palette_%s ; ' "${pane_id}" "${reset_role}"
    # Retire overrides published by the original, unnamespaced hook too.
    printf 'set-option -pu -t %s @beck_%s ; ' "${pane_id}" "${reset_role}"
  done
  printf 'set-option -pu -t %s @beck_theme_owner ; set-option -pu -t %s @beck_theme_token ; ' "${pane_id}" "${pane_id}"
}

watch_owner() {
  local socket_path="$1"
  local pane_id="$2"
  local owner_pid="$3"
  local pane_tty="$4"
  local expected_identity="$5"
  local expected_token="$6"
  local current_token current_identity
  local reset_commands
  reset_commands="$(clear_commands "${pane_id}")"
  while current_token="$(tmux -N -S "${socket_path}" show-options -pqv -t "${pane_id}" @beck_theme_token 2>/dev/null)"; do
    [[ "${current_token}" == "${expected_token}" ]] || return 0
    if ! current_identity="$(owner_identity "${owner_pid}" "${pane_tty}")" ||
        [[ "${current_identity}" != "${expected_identity}" ]]; then
      # Compare and clear inside tmux's command queue. A newer publication
      # between the process check and this command must survive the old watcher.
      tmux -N -S "${socket_path}" if-shell -F -t "${pane_id}" \
        "#{==:#{@beck_theme_token},${expected_token}}" "${reset_commands}" 2>/dev/null || true
      return 0
    fi
    sleep 1
  done
}

# run-shell uses /bin/sh, so use portable single-quote escaping (not Bash %q).
shell_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

main() {
  local action="${1:-}"
  local -a action_arguments=("${@:2}")
  local -a tmux_commands=()
  local -A supplied_roles=()
  local palette_argument palette_role palette_color reset_role
  local owner_pid="${PPID}"
  local force_reset=false
  local palette_offset=0

  if [[ "${action_arguments[0]:-}" == --owner ]]; then
    owner_pid="${action_arguments[1]:-}"
    palette_offset=2
  elif [[ "${action}" == reset && "${action_arguments[0]:-}" == --force ]]; then
    force_reset=true
    palette_offset=1
  fi
  local -a palette_arguments=("${action_arguments[@]:${palette_offset}}")

  case "${action}" in
    -h|--help) usage; return ;;
    set) ((${#palette_arguments[@]} > 0)) || fail 'set requires at least one ROLE=#RRGGBB' ;;
    reset) ((${#palette_arguments[@]} == 0)) || fail 'reset takes no palette arguments' ;;
    *) usage >&2; exit 2 ;;
  esac

  # Validate everything before issuing any mutations. Values are passed as
  # individual argv entries, never evaluated as shell or tmux source text.
  for palette_argument in "${palette_arguments[@]}"; do
    [[ "${palette_argument}" =~ ^(bg|surface|cursor|border|fg|muted|green|cyan|yellow|purple|red|window_active_fg|window_active_bg|window_inactive_fg|window_inactive_bg)=(#[[:xdigit:]]{6})$ ]] ||
      fail "invalid palette entry: ${palette_argument}"
    palette_role="${BASH_REMATCH[1]}"
    palette_color="${BASH_REMATCH[2]}"
    [[ -z "${supplied_roles[${palette_role}]:-}" ]] || fail "duplicate role: ${palette_role}"
    supplied_roles["${palette_role}"]="${palette_color}"
  done

  [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]] || fail 'TMUX_PANE must identify the calling pane'
  [[ "${TMUX:-}" =~ ^(.+),[0-9]+,[0-9]+$ ]] || fail 'TMUX must identify the calling server'
  local socket_path="${BASH_REMATCH[1]}"
  local pane_id="${TMUX_PANE}"
  [[ "${owner_pid}" =~ ^[1-9][0-9]*$ ]] || fail 'owner must be a positive process ID'

  local reset_commands
  reset_commands="$(clear_commands "${pane_id}")"
  if [[ "${action}" == reset ]]; then
    if "${force_reset}"; then
      tmux -N -S "${socket_path}" source-file - <<<"${reset_commands}"
    else
      # Reset may run during suspend, so it checks the publisher PID without
      # requiring the publisher to still own the foreground terminal.
      tmux -N -S "${socket_path}" if-shell -F -t "${pane_id}" \
        "#{m:${owner_pid}:*,#{@beck_theme_owner}}" "${reset_commands}"
    fi
    return
  fi

  local pane_tty
  local publishing_identity
  pane_tty="$(tmux -N -S "${socket_path}" display-message -p -t "${pane_id}" '#{pane_tty}')"
  publishing_identity="$(owner_identity "${owner_pid}" "${pane_tty}")" ||
    fail 'owner must be a running foreground application in this pane'
  local publication_token="${BASHPID}-${RANDOM}-${RANDOM}"
  local script_directory
  script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  local script_path="${script_directory}/$(basename -- "${BASH_SOURCE[0]}")"
  local watcher_command
  watcher_command="exec $(shell_quote "${BASH}") $(shell_quote "${script_path}") _watch $(shell_quote "${socket_path}") $(shell_quote "${pane_id}") $(shell_quote "${owner_pid}") $(shell_quote "${pane_tty}") $(shell_quote "${publishing_identity}") $(shell_quote "${publication_token}")"
  # run-shell expands tmux formats even inside shell quotes.
  local watcher_format="${watcher_command//#/##}"

  for reset_role in "${PALETTE_ROLES[@]}"; do
    tmux_commands+=(set-option -pu -t "${pane_id}" "@beck_palette_${reset_role}" ';')
    tmux_commands+=(set-option -pu -t "${pane_id}" "@beck_${reset_role}" ';')
  done
  for palette_role in "${PALETTE_ROLES[@]}"; do
    if [[ -n "${supplied_roles[${palette_role}]:-}" ]]; then
      tmux_commands+=(set-option -p -t "${pane_id}" "@beck_palette_${palette_role}"
        "${supplied_roles[${palette_role}]}" ';')
    fi
  done
  tmux_commands+=(set-option -p -t "${pane_id}" @beck_theme_owner "${publishing_identity}" ';'
    set-option -p -t "${pane_id}" @beck_theme_token "${publication_token}" ';'
    run-shell -b -t "${pane_id}" "${watcher_format}")
  # -N refuses to start a server if the application's original server is gone.
  # The watcher belongs to tmux's job process, not the application's process
  # group, so killing the entire application job cannot kill its cleanup too.
  tmux -N -S "${socket_path}" "${tmux_commands[@]}"
}

if [[ "${1:-}" == _watch ]]; then
  (($# == 7)) || fail 'invalid internal watcher arguments'
  [[ "$3" =~ ^%[0-9]+$ && "$4" =~ ^[1-9][0-9]*$ && "$7" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] ||
    fail 'invalid internal watcher target'
  watch_owner "${@:2}"
else
  main "$@"
fi
