#!/usr/bin/env bash

# Build, validate, and install a requested tmux release without interrupting
# the running server. Switching servers is a separate, explicit action.

set -Eeuo pipefail

readonly TARGET_TMUX_VERSION="${1:-}"
readonly REQUESTED_ACTION="${2:-check}"
readonly SWITCH_CONFIRMATION="${3:-}"
readonly INSTALL_PREFIX="/usr/local"
readonly INSTALLED_TMUX_PATH="${INSTALL_PREFIX}/bin/tmux"
readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIRECTORY="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly TMUX_CONFIG_PATH="${PROJECT_DIRECTORY}/tmux.conf"
readonly RELEASE_URL="https://github.com/tmux/tmux/releases/download/${TARGET_TMUX_VERSION}/tmux-${TARGET_TMUX_VERSION}.tar.gz"

migration_directory=""
validation_socket=""
built_tmux_path=""

info() { printf '[tmux-migrate] %s\n' "$*"; }
die() { printf '[tmux-migrate] error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./migrate-tmux.sh VERSION check
  ./migrate-tmux.sh VERSION install
  ./migrate-tmux.sh VERSION switch [--kill-old-server]

check
  Download, build, and validate VERSION in a temporary directory. This does
  not install anything or stop the running tmux server.

install
  Install build dependencies, run the same isolated validation, preserve the
  currently installed binary under its versioned name, and install VERSION
  under /usr/local. The running server is not stopped.

switch
  Start a server using the installed VERSION. Run this outside tmux after
  closing the old sessions normally. If a server still exists, the command
  refuses to stop it unless --kill-old-server is supplied.

Examples:
  ./migrate-tmux.sh 3.6b check
  ./migrate-tmux.sh 3.6b install
  ./migrate-tmux.sh 3.6b switch
EOF
}

validate_arguments() {
  if [[ "${TARGET_TMUX_VERSION}" == "-h" \
      || "${TARGET_TMUX_VERSION}" == "--help" \
      || "${TARGET_TMUX_VERSION}" == "help" ]]; then
    usage
    exit 0
  fi
  [[ "${TARGET_TMUX_VERSION}" =~ ^[0-9]+([.][0-9]+)+[a-z]?$ ]] || \
    die "VERSION must look like 3.6b or 3.7"
}

run_as_root() {
  if ((EUID == 0)); then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required"
    sudo "$@"
  fi
}

cleanup() {
  if [[ -n "${validation_socket}" && -n "${built_tmux_path}" ]]; then
    "${built_tmux_path}" -S "${validation_socket}" kill-server >/dev/null 2>&1 || true
  fi
  if [[ -n "${migration_directory}" && -d "${migration_directory}" ]]; then
    rm -rf -- "${migration_directory}"
  fi
}

require_build_dependencies() {
  local required_command

  for required_command in bison cc curl make pkg-config tar; do
    command -v "${required_command}" >/dev/null 2>&1 || \
      die "required build command is unavailable: ${required_command}"
  done
  pkg-config --exists libevent || die "libevent development files are unavailable"
  pkg-config --exists ncurses || die "ncurses development files are unavailable"
}

install_build_dependencies() {
  command -v apt-get >/dev/null 2>&1 || die "this migration script targets Ubuntu/Debian"
  info 'installing build dependencies'
  run_as_root apt-get update
  run_as_root apt-get install -y \
    bison build-essential pkg-config libevent-dev libncurses-dev curl
}

back_up_config() {
  local existing_backup_path
  local backup_timestamp
  local backup_path

  [[ -f "${TMUX_CONFIG_PATH}" ]] || die "config not found: ${TMUX_CONFIG_PATH}"
  existing_backup_path="$(find "${PROJECT_DIRECTORY}" -maxdepth 1 -type f \
    -name "tmux.conf.bak.pre-${TARGET_TMUX_VERSION}.*" -print -quit)"
  if [[ -n "${existing_backup_path}" ]]; then
    info "using existing config backup: ${existing_backup_path}"
    return
  fi

  backup_timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_path="${TMUX_CONFIG_PATH}.bak.pre-${TARGET_TMUX_VERSION}.${backup_timestamp}"
  cp -p -- "${TMUX_CONFIG_PATH}" "${backup_path}"
  info "backed up config: ${backup_path}"
}

download_release() {
  local archive_path="$1"

  info "downloading tmux ${TARGET_TMUX_VERSION}"
  curl --fail --location --retry 3 --output "${archive_path}" "${RELEASE_URL}"
}

build_release() {
  local source_directory="$1"
  local build_jobs
  local -a configure_arguments

  build_jobs="$(nproc 2>/dev/null || printf '2')"
  configure_arguments=("--prefix=${INSTALL_PREFIX}")
  if "${source_directory}/configure" --help | grep -q -- '--disable-utf8proc'; then
    configure_arguments+=(--disable-utf8proc)
  fi

  info "building tmux ${TARGET_TMUX_VERSION}"
  (
    cd -- "${source_directory}"
    ./configure "${configure_arguments[@]}"
    make -s -j"${build_jobs}"
  )
  built_tmux_path="${source_directory}/tmux"
  [[ "$("${built_tmux_path}" -V)" == "tmux ${TARGET_TMUX_VERSION}" ]] || \
    die "built binary did not report tmux ${TARGET_TMUX_VERSION}"
}

validate_config() {
  local configured_terminal

  validation_socket="${migration_directory}/validation.sock"
  info "validating ${TMUX_CONFIG_PATH} with tmux ${TARGET_TMUX_VERSION}"
  "${built_tmux_path}" -S "${validation_socket}" -f "${TMUX_CONFIG_PATH}" \
    new-session -d -s migration-check
  configured_terminal="$(
    "${built_tmux_path}" -S "${validation_socket}" show-options -gv default-terminal
  )"
  [[ "${configured_terminal}" == "tmux-256color" ]] || \
    die "configuration selected unexpected terminal: ${configured_terminal}"
  "${built_tmux_path}" -S "${validation_socket}" list-keys \
    -T copy-mode-vi / >/dev/null
  "${built_tmux_path}" -S "${validation_socket}" list-keys \
    -T copy-mode-vi : >/dev/null
  "${built_tmux_path}" -S "${validation_socket}" kill-server
  validation_socket=""
}

prepare_release() {
  local archive_path
  local source_directory

  migration_directory="$(mktemp -d -t "tmux-${TARGET_TMUX_VERSION}-migrate.XXXXXXXX")"
  archive_path="${migration_directory}/tmux-${TARGET_TMUX_VERSION}.tar.gz"
  source_directory="${migration_directory}/tmux-${TARGET_TMUX_VERSION}"
  download_release "${archive_path}"
  tar -xzf "${archive_path}" -C "${migration_directory}"
  build_release "${source_directory}"
  validate_config
}

back_up_installed_tmux() {
  local installed_version_output
  local installed_version
  local installed_backup_path
  local backup_version_output

  [[ -x "${INSTALLED_TMUX_PATH}" ]] || return
  installed_version_output="$("${INSTALLED_TMUX_PATH}" -V)"
  installed_version="${installed_version_output#tmux }"
  [[ "${installed_version}" =~ ^[0-9]+([.][0-9]+)+[a-z]?$ ]] || \
    die "installed tmux reported an unsafe version: ${installed_version_output}"
  if [[ "${installed_version}" == "${TARGET_TMUX_VERSION}" ]]; then
    info "tmux ${TARGET_TMUX_VERSION} is already the installed binary"
    return
  fi

  installed_backup_path="${INSTALL_PREFIX}/bin/tmux-${installed_version}"
  if [[ -e "${installed_backup_path}" ]]; then
    [[ -x "${installed_backup_path}" ]] || \
      die "existing backup is not executable: ${installed_backup_path}"
    backup_version_output="$("${installed_backup_path}" -V)"
    [[ "${backup_version_output}" == "${installed_version_output}" ]] || \
      die "existing backup has unexpected version: ${backup_version_output}"
    info "using existing binary backup: ${installed_backup_path}"
    return
  fi

  run_as_root cp -p -- "${INSTALLED_TMUX_PATH}" "${installed_backup_path}"
  info "preserved ${installed_version_output} as ${installed_backup_path}"
}

install_release() {
  local source_directory
  local target_backup_path

  source_directory="${migration_directory}/tmux-${TARGET_TMUX_VERSION}"
  target_backup_path="${INSTALL_PREFIX}/bin/tmux-${TARGET_TMUX_VERSION}"
  back_up_installed_tmux
  info "installing tmux ${TARGET_TMUX_VERSION} under ${INSTALL_PREFIX}"
  run_as_root make -C "${source_directory}" install
  [[ "$("${INSTALLED_TMUX_PATH}" -V)" == "tmux ${TARGET_TMUX_VERSION}" ]] || \
    die "installed binary did not report tmux ${TARGET_TMUX_VERSION}"
  run_as_root cp -p -- "${INSTALLED_TMUX_PATH}" "${target_backup_path}"
}

check_action() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  require_build_dependencies
  prepare_release
  info "tmux ${TARGET_TMUX_VERSION} built successfully and passed config validation"
}

install_action() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  back_up_config
  install_build_dependencies
  require_build_dependencies
  prepare_release
  install_release

  info "installed: ${INSTALLED_TMUX_PATH} ${TARGET_TMUX_VERSION}"
  info 'the running server keeps its existing version; pane processes were not interrupted'
  info "after leaving tmux, run: ${SCRIPT_DIRECTORY}/migrate-tmux.sh ${TARGET_TMUX_VERSION} switch"
  info "run 'hash -r' in existing shells if they cached the previous binary"
}

switch_action() {
  local installed_version

  [[ -z "${TMUX:-}" ]] || die "switch must be run outside tmux"
  [[ -x "${INSTALLED_TMUX_PATH}" ]] || \
    die "${INSTALLED_TMUX_PATH} is not installed; run '${SCRIPT_DIRECTORY}/migrate-tmux.sh ${TARGET_TMUX_VERSION} install' first"
  installed_version="$("${INSTALLED_TMUX_PATH}" -V)"
  [[ "${installed_version}" == "tmux ${TARGET_TMUX_VERSION}" ]] || \
    die "target is not installed: expected tmux ${TARGET_TMUX_VERSION}, found ${installed_version}; run '${SCRIPT_DIRECTORY}/migrate-tmux.sh ${TARGET_TMUX_VERSION} install' first"

  if "${INSTALLED_TMUX_PATH}" list-sessions >/dev/null 2>&1; then
    if [[ "${SWITCH_CONFIRMATION}" != "--kill-old-server" ]]; then
      "${INSTALLED_TMUX_PATH}" list-panes -a \
        -F 'session=#{session_name} window=#{window_index} pane=#{pane_index} command=#{pane_current_command}'
      die "a server is still running; close its sessions or rerun with --kill-old-server"
    fi
    info "stopping the existing server and all remaining pane processes"
    "${INSTALLED_TMUX_PATH}" kill-server
  fi

  info "starting tmux ${TARGET_TMUX_VERSION}"
  exec "${INSTALLED_TMUX_PATH}" new-session -s main
}

validate_arguments
case "${REQUESTED_ACTION}" in
  check)
    (($# <= 2)) || die "check does not accept additional arguments"
    check_action
    ;;
  install)
    (($# <= 2)) || die "install does not accept additional arguments"
    install_action
    ;;
  switch)
    (($# <= 3)) || die "switch accepts only --kill-old-server"
    [[ -z "${SWITCH_CONFIRMATION}" || "${SWITCH_CONFIRMATION}" == "--kill-old-server" ]] || \
      die "switch accepts only --kill-old-server"
    switch_action
    ;;
  -h|--help|help)
    (($# <= 2)) || die "help does not accept additional arguments"
    usage
    ;;
  *) usage >&2; exit 2 ;;
esac
