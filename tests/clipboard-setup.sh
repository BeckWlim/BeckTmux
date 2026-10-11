#!/usr/bin/env bash

# Apt fixtures cover the setup interface used by Pop!_OS and Ubuntu-based WSL.
set -Eeuo pipefail
readonly PROJECT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly FIXTURE_DIRECTORY="$(mktemp -d /tmp/beck-clipboard-setup.XXXXXXXX)"
trap 'rm -rf -- "${FIXTURE_DIRECTORY}"' EXIT
fail() { printf '[clipboard-setup-test] FAIL: %s\n' "$*" >&2; exit 1; }
for scenario in linux wsl package-failure; do
  scenario_directory="${FIXTURE_DIRECTORY}/${scenario}"
  mkdir -p "${scenario_directory}/bin" "${scenario_directory}/config"
  for utility in bash dirname mkdir install cat grep chmod; do
    ln -s "$(command -v "${utility}")" "${scenario_directory}/bin/${utility}"
  done
  cat >"${scenario_directory}/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  clone) mkdir -p "$3/.git" "$3/scripts" ;;
  -C)
    if [[ "$3" == rev-parse ]]; then
      printf '%s\n' e5f427e9dcf180ca92e2f8af47ba07f644fd4585
    fi ;;
esac
EOF
  cat >"${scenario_directory}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BECK_SETUP_FIXTURE}/apt.log"
[[ "${BECK_SETUP_SCENARIO}" != package-failure ]] || exit 100
if [[ "$1" == install ]]; then
  shift 2
  for package_name in "$@"; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${BECK_SETUP_FIXTURE}/bin/${package_name}"
    /bin/chmod +x "${BECK_SETUP_FIXTURE}/bin/${package_name}"
  done
fi
EOF
  cat >"${scenario_directory}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
  chmod +x "${scenario_directory}/bin/"{git,apt-get,sudo}
  fixture_wsl=""
  if [[ "${scenario}" == wsl ]]; then
    fixture_wsl=fixture
    printf '#!/usr/bin/env bash\nexit 0\n' >"${scenario_directory}/bin/powershell.exe"
    chmod +x "${scenario_directory}/bin/powershell.exe"
  fi
  setup_status=0
  env PATH="${scenario_directory}/bin" WSL_DISTRO_NAME="${fixture_wsl}" \
    BECK_SETUP_FIXTURE="${scenario_directory}" BECK_SETUP_SCENARIO="${scenario}" \
    BECK_TMUX_DIRECTORY="${scenario_directory}/project" XDG_CONFIG_HOME="${scenario_directory}/config" \
    bash "${PROJECT_DIRECTORY}/scripts/setup-clipboard.sh" --install-deps || setup_status=$?
  if [[ "${scenario}" == package-failure ]]; then
    [[ "${setup_status}" != 0 ]] || fail 'package failure hidden'
    [[ ! -d "${scenario_directory}/project/plugins/tmux-fzf" ]] || fail 'plugin installed after dependency failure'
    continue
  fi
  [[ "${setup_status}" == 0 ]] || fail "${scenario}: setup failed"
  cmp -s "${PROJECT_DIRECTORY}/scripts/clipboard-history.sh" \
    "${scenario_directory}/project/scripts/clipboard-history.sh" || fail 'adapter not deployed'
  "${scenario_directory}/project/plugins/tmux-fzf/scripts/clipboard.sh" --help \
    >"${scenario_directory}/plugin-help"
  grep -q 'j/k selects' "${scenario_directory}/plugin-help" || fail 'plugin entry does not delegate to adapter'
  if [[ "${scenario}" == wsl ]]; then
    grep -qx 'install -y fzf' "${scenario_directory}/apt.log" || fail 'WSL installed Linux clipboard daemon'
    [[ ! -e "${scenario_directory}/config/autostart/beck-clipboard.desktop" ]] || fail 'WSL added Linux autostart'
    [[ -f "${scenario_directory}/project/scripts/windows-clipboard-history.ps1" ]] || fail 'Windows provider missing'
  else
    grep -qx 'install -y fzf copyq' "${scenario_directory}/apt.log" || fail 'Linux did not use distro packages'
    [[ -f "${scenario_directory}/config/autostart/beck-clipboard.desktop" ]] || fail 'desktop autostart missing'
  fi
  # An existing startup entry is user-owned and must survive repeat setup.
  mkdir -p "${scenario_directory}/config/autostart"
  printf 'custom entry\n' >"${scenario_directory}/config/autostart/beck-clipboard.desktop"
  env PATH="${scenario_directory}/bin" WSL_DISTRO_NAME="${fixture_wsl}" \
    BECK_TMUX_DIRECTORY="${scenario_directory}/project" XDG_CONFIG_HOME="${scenario_directory}/config" \
    bash "${PROJECT_DIRECTORY}/scripts/setup-clipboard.sh"
  grep -qx 'custom entry' "${scenario_directory}/config/autostart/beck-clipboard.desktop" || fail 'existing startup entry changed'
  [[ $(wc -l <"${scenario_directory}/apt.log") == 2 ]] || fail 'repeat setup reinstalled dependencies'
  printf '[clipboard-setup-test] ok: %s distro packages, deployment, idempotence\n' "${scenario}"
done

# Confirm the original entry point dispatches --clipboard as an optional step.
(
  source "${PROJECT_DIRECTORY}/scripts/setup.sh"
  install_tmux_config() { :; }
  info() { :; }
  run_optional_step() { printf '%s\n' "$*" >>"${FIXTURE_DIRECTORY}/dispatch"; }
  main --skip-eza --skip-synth-shell --clipboard
)
grep -q 'setup-clipboard.sh --install-deps' "${FIXTURE_DIRECTORY}/dispatch" || fail 'setup.sh did not dispatch clipboard integration'
printf '[clipboard-setup-test] ok: setup.sh --clipboard dispatch\n'
