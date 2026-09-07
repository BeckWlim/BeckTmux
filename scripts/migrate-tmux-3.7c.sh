#!/usr/bin/env bash

# Install tmux 3.7c without interrupting a running tmux 3.4 server, then switch
# servers in a separate, explicit step after pane processes have been saved.

set -Eeuo pipefail

readonly TARGET_TMUX_VERSION="3.7c"
readonly RELEASE_URL="https://github.com/tmux/tmux/releases/download/${TARGET_TMUX_VERSION}/tmux-${TARGET_TMUX_VERSION}.tar.gz"
readonly INSTALL_PREFIX="/usr/local"
readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIRECTORY="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
readonly TMUX_CONFIG_PATH="${PROJECT_DIRECTORY}/tmux.conf"
readonly REQUESTED_ACTION="${1:-install}"
readonly SWITCH_CONFIRMATION="${2:-}"

migration_directory=""
validation_socket=""
built_tmux_path=""

info() { printf '[tmux-migrate] %s\n' "$*"; }
die() { printf '[tmux-migrate] error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  ./migrate-tmux-3.7c.sh install
  ./migrate-tmux-3.7c.sh switch [--kill-old-server]

install
  Back up tmux.conf, build and validate tmux 3.7c, install it under
  /usr/local, and remove Ubuntu's tmux 3.4 package. This does not stop the
  running tmux server and is safe to run from an existing tmux session.

switch
  Start a tmux 3.7c server. Run this outside tmux after closing the old
  sessions normally. If an old server still exists, the command refuses to
  stop it unless --kill-old-server is supplied.
EOF
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

back_up_config() {
  local existing_backup_path
  local backup_timestamp
  local backup_path

  [[ -f "${TMUX_CONFIG_PATH}" ]] || die "config not found: ${TMUX_CONFIG_PATH}"
  existing_backup_path="$(find "${PROJECT_DIRECTORY}" -maxdepth 1 -type f \
    -name 'tmux.conf.bak.pre-3.7c.*' -print -quit)"
  if [[ -n "${existing_backup_path}" ]]; then
    info "using existing backup: ${existing_backup_path}"
    return
  fi

  backup_timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_path="${TMUX_CONFIG_PATH}.bak.pre-3.7c.${backup_timestamp}"
  cp -p -- "${TMUX_CONFIG_PATH}" "${backup_path}"
  info "backed up config: ${backup_path}"
}

install_build_dependencies() {
  command -v apt-get >/dev/null 2>&1 || die "this migration script targets Ubuntu/Debian"
  info "installing build dependencies"
  run_as_root apt-get update
  run_as_root apt-get install -y \
    bison build-essential pkg-config libevent-dev libncurses-dev curl
}

download_release() {
  local archive_path="$1"

  info "downloading tmux ${TARGET_TMUX_VERSION}"
  curl --fail --location --retry 3 --output "${archive_path}" "${RELEASE_URL}"
}

build_release() {
  local source_directory="$1"
  local build_jobs

  build_jobs="$(nproc 2>/dev/null || printf '2')"
  info "building tmux ${TARGET_TMUX_VERSION}"
  (
    cd -- "${source_directory}"
    ./configure --prefix="${INSTALL_PREFIX}" --disable-utf8proc
    make -j"${build_jobs}"
  )
  built_tmux_path="${source_directory}/tmux"
  [[ "$("${built_tmux_path}" -V)" == "tmux ${TARGET_TMUX_VERSION}" ]] || \
    die "built binary did not report tmux ${TARGET_TMUX_VERSION}"
}

validate_config() {
  validation_socket="${migration_directory}/validation.sock"
  info "validating ${TMUX_CONFIG_PATH} with tmux ${TARGET_TMUX_VERSION}"
  "${built_tmux_path}" -S "${validation_socket}" -f "${TMUX_CONFIG_PATH}" \
    new-session -d -s migration-check

  "${built_tmux_path}" -S "${validation_socket}" list-keys -T copy-mode-vi |
    grep -F 'command-prompt -el -T search -p /' >/dev/null || \
    die "the 3.7c search prompt binding was not activated"
  "${built_tmux_path}" -S "${validation_socket}" list-keys -T copy-mode-vi |
    grep -F 'command-prompt -el -p :' >/dev/null || \
    die "the 3.7c goto-line prompt binding was not activated"

  "${built_tmux_path}" -S "${validation_socket}" kill-server
  validation_socket=""
}

install_release() {
  local source_directory="$1"

  info "installing tmux ${TARGET_TMUX_VERSION} under ${INSTALL_PREFIX}"
  run_as_root make -C "${source_directory}" install
  [[ "$("${INSTALL_PREFIX}/bin/tmux" -V)" == "tmux ${TARGET_TMUX_VERSION}" ]] || \
    die "installed binary did not report tmux ${TARGET_TMUX_VERSION}"
}

remove_ubuntu_tmux() {
  local package_status

  package_status="$(dpkg-query -W -f='${Status}' tmux 2>/dev/null || true)"
  if [[ "${package_status}" == "install ok installed" ]]; then
    info "removing Ubuntu's tmux package; the running server will continue"
    run_as_root apt-get remove -y tmux
  fi
}

install_action() {
  local archive_path
  local source_directory

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  back_up_config
  install_build_dependencies

  migration_directory="$(mktemp -d -t tmux-3.7c-migrate.XXXXXXXX)"
  archive_path="${migration_directory}/tmux-${TARGET_TMUX_VERSION}.tar.gz"
  source_directory="${migration_directory}/tmux-${TARGET_TMUX_VERSION}"
  download_release "${archive_path}"
  tar -xzf "${archive_path}" -C "${migration_directory}"
  build_release "${source_directory}"
  validate_config
  install_release "${source_directory}"
  remove_ubuntu_tmux

  info "installed: ${INSTALL_PREFIX}/bin/tmux ${TARGET_TMUX_VERSION}"
  info "the current server is still tmux 3.4; do not kill it until pane work is saved"
  info "after leaving tmux, run: ${SCRIPT_DIRECTORY}/migrate-tmux-3.7c.sh switch"
  info "run 'hash -r' in existing shells if they cached /usr/bin/tmux"
}

switch_action() {
  local installed_version

  [[ -z "${TMUX:-}" ]] || die "switch must be run outside tmux"
  [[ -x "${INSTALL_PREFIX}/bin/tmux" ]] || die "${INSTALL_PREFIX}/bin/tmux is not installed"
  installed_version="$("${INSTALL_PREFIX}/bin/tmux" -V)"
  [[ "${installed_version}" == "tmux ${TARGET_TMUX_VERSION}" ]] || \
    die "expected tmux ${TARGET_TMUX_VERSION}, found ${installed_version}"

  if "${INSTALL_PREFIX}/bin/tmux" list-sessions >/dev/null 2>&1; then
    if [[ "${SWITCH_CONFIRMATION}" != "--kill-old-server" ]]; then
      "${INSTALL_PREFIX}/bin/tmux" list-panes -a \
        -F 'session=#{session_name} window=#{window_index} pane=#{pane_index} command=#{pane_current_command}'
      die "a server is still running; close its sessions or rerun with --kill-old-server"
    fi
    info "stopping the existing server and all remaining pane processes"
    "${INSTALL_PREFIX}/bin/tmux" kill-server
  fi

  info "starting tmux ${TARGET_TMUX_VERSION}"
  exec "${INSTALL_PREFIX}/bin/tmux" new-session -s main
}

case "${REQUESTED_ACTION}" in
  install)
    (($# <= 1)) || die "install does not accept additional arguments"
    install_action
    ;;
  switch)
    (($# <= 2)) || die "switch accepts only --kill-old-server"
    [[ -z "${SWITCH_CONFIRMATION}" || "${SWITCH_CONFIRMATION}" == "--kill-old-server" ]] || \
      die "switch accepts only --kill-old-server"
    switch_action
    ;;
  -h|--help|help)
    (($# == 1)) || die "help does not accept additional arguments"
    usage
    ;;
  *) usage >&2; exit 2 ;;
esac
