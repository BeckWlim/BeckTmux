#!/usr/bin/env bash

# Install the optional clipboard integration without changing shell setup.
set -Eeuo pipefail
readonly SOURCE_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIRECTORY="${BECK_TMUX_DIRECTORY:-${SOURCE_DIRECTORY}}"
export PATH="${PATH}:${PROJECT_DIRECTORY}/plugins/clipboard-runtime/usr/bin"
readonly PLUGIN_DIRECTORY="${PROJECT_DIRECTORY}/plugins/tmux-fzf"
readonly PLUGIN_REVISION=e5f427e9dcf180ca92e2f8af47ba07f644fd4585

install_dependencies=0
local_runtime=0
autostart=1
for setup_argument in "$@"; do
case "${setup_argument}" in
  -h|--help)
    printf '%s\n' 'Usage: setup-clipboard.sh [--install-deps|--local-runtime] [--no-autostart]' \
      'Installs pinned tmux-fzf with the maintained clipboard adapter.' \
      '--install-deps uses distro packages on Pop!_OS, Ubuntu and Debian (apt).' \
      '--local-runtime extracts distro packages under plugins/ (no sudo, shared libraries must already exist).' \
      '--no-autostart skips the Linux desktop autostart entry.' \
      'WSL requires fzf and Windows PowerShell interop; Linux also requires CopyQ.'
    exit ;;
  --install-deps) install_dependencies=1 ;;
  --local-runtime) local_runtime=1 ;;
  --no-autostart) autostart=0 ;;
  *) exit 2 ;;
esac
done
((install_dependencies == 0 || local_runtime == 0)) || exit 2
wsl=0
if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
  wsl=1
fi
required_commands=(git fzf)
runtime_packages=(fzf)
if ((wsl)); then
  command -v powershell.exe >/dev/null || {
    printf '[clipboard-setup] Enable Windows PowerShell interop in WSL first.\n' >&2
    exit 1
  }
else
  required_commands+=(copyq)
  runtime_packages+=(copyq copyq-plugins)
fi
if ((install_dependencies)); then
  missing_packages=()
  for required_command in "${required_commands[@]}"; do
    command -v "${required_command}" >/dev/null || missing_packages+=("${required_command}")
  done
  if ((${#missing_packages[@]})); then
    command -v apt-get >/dev/null || {
      printf '[clipboard-setup] Install git, fzf and CopyQ with your package manager.\n' >&2
      exit 1
    }
    privilege_command=()
    [[ ${EUID} == 0 ]] || privilege_command=(sudo)
    "${privilege_command[@]}" apt-get update
    "${privilege_command[@]}" apt-get install -y "${missing_packages[@]}"
  fi
fi

if [[ ! -d "${PLUGIN_DIRECTORY}/.git" ]]; then
  git clone https://github.com/sainnhe/tmux-fzf.git "${PLUGIN_DIRECTORY}"
  git -C "${PLUGIN_DIRECTORY}" checkout --detach "${PLUGIN_REVISION}"
fi
if [[ "$(git -C "${PLUGIN_DIRECTORY}" rev-parse HEAD)" != "${PLUGIN_REVISION}" ]]; then
  printf '[clipboard-setup] Existing plugin revision differs; preserved it.\n' >&2
  exit 1
fi

if ((local_runtime)); then
  runtime_directory="${PROJECT_DIRECTORY}/plugins/clipboard-runtime"
  mkdir -p "${runtime_directory}/packages"
  (cd "${runtime_directory}/packages"; apt-get download "${runtime_packages[@]}")
  for package_path in "${runtime_directory}"/packages/*.deb; do
    dpkg-deb -x "${package_path}" "${runtime_directory}"
  done
fi
for required_command in "${required_commands[@]}"; do
  command -v "${required_command}" >/dev/null || {
    printf '[clipboard-setup] Missing %s; install it or use --local-runtime.\n' "${required_command}" >&2
    exit 1
  }
done
mkdir -p "${PROJECT_DIRECTORY}/scripts"
if [[ "${SOURCE_DIRECTORY}" != "${PROJECT_DIRECTORY}" ]]; then
  install -m 755 "${SOURCE_DIRECTORY}/scripts/clipboard-history.sh" "${PROJECT_DIRECTORY}/scripts/clipboard-history.sh"
  install -m 755 "${SOURCE_DIRECTORY}/scripts/setup-clipboard.sh" "${PROJECT_DIRECTORY}/scripts/setup-clipboard.sh"
  install -m 644 "${SOURCE_DIRECTORY}/scripts/windows-clipboard-history.ps1" "${PROJECT_DIRECTORY}/scripts/windows-clipboard-history.ps1"
fi
# Delegate to the maintained adapter instead of installing a second copy of it.
cat >"${PLUGIN_DIRECTORY}/scripts/clipboard.sh" <<'ADAPTER'
#!/usr/bin/env bash
set -Eeuo pipefail
export BECK_TMUX_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec bash "${BECK_TMUX_DIRECTORY}/scripts/clipboard-history.sh" "$@"
ADAPTER
chmod +x "${PLUGIN_DIRECTORY}/scripts/clipboard.sh"
if ((autostart && !wsl)); then
  autostart_directory="${XDG_CONFIG_HOME:-${HOME}/.config}/autostart"
  mkdir -p "${autostart_directory}"
  autostart_path="${autostart_directory}/beck-clipboard.desktop"
  if [[ ! -e "${autostart_path}" ]]; then
    cat >"${autostart_path}" <<EOF
[Desktop Entry]
Type=Application
Name=Beck clipboard history
Exec=bash "${PROJECT_DIRECTORY}/scripts/clipboard-history.sh" start
Terminal=false
NoDisplay=true
EOF
  fi
fi
printf '%s\n' '[clipboard-setup] Ready. Run clipboard-history.sh start in your desktop session, then reload tmux with C-s R.'
