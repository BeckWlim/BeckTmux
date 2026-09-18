#!/usr/bin/env bash

# Fake external installers; never provision packages or edit the user's shell.
set -Eeuo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SETUP_SCRIPT="${TEST_DIRECTORY}/../scripts/setup.sh"
readonly FIXTURE_DIRECTORY="$(mktemp -d /tmp/beck-setup-tests.XXXXXXXX)"
trap 'rm -rf -- "${FIXTURE_DIRECTORY}"' EXIT

fail() { printf '[setup-test] FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "${FIXTURE_DIRECTORY}/bin"
for utility in bash dirname mkdir cp date grep; do
  ln -s "$(command -v "${utility}")" "${FIXTURE_DIRECTORY}/bin/${utility}"
done
cat >"${FIXTURE_DIRECTORY}/bin/cat" <<'EOF'
#!/usr/bin/env bash
[[ "${SCENARIO}" != alias-failure ]] || exit 73
exec /bin/cat "$@"
EOF
cat >"${FIXTURE_DIRECTORY}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'apt %s\n' "$*" >>"${SCENARIO_DIRECTORY}/commands.log"
case "$1" in
  update) [[ "${SCENARIO}" != update-failure ]] ;;
  install)
    [[ "${SCENARIO}" != missing-package && "${SCENARIO}" != both-fail ]] || exit 100
    /bin/cp "${SCENARIO_DIRECTORY}/../bin/tmux" "${SCENARIO_DIRECTORY}/bin/eza"
    ;;
  *) exit 99 ;;
esac
EOF
cat >"${FIXTURE_DIRECTORY}/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat >"${FIXTURE_DIRECTORY}/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${FIXTURE_DIRECTORY}/bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"${SCENARIO_DIRECTORY}/commands.log"
case "$1" in
  clone)
    [[ "${SCENARIO}" != clone-failure && "${SCENARIO}" != both-fail ]] || exit 128
    mkdir -p "$4/.git"
    [[ "${SCENARIO}" != missing-installer ]] || exit 0
    /bin/cp "${SCENARIO_DIRECTORY}/../bin/tmux" "$4/setup.sh"
    ;;
  -C)
    [[ "$3" != pull || "${SCENARIO}" != pull-failure ]] || exit 128
    [[ "$3" != submodule || "${SCENARIO}" != submodule-failure ]] || exit 128
    ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${FIXTURE_DIRECTORY}/bin/"{apt-get,sudo,tmux,git,cat}

for scenario in missing-package update-failure clone-failure pull-failure submodule-failure missing-installer both-fail alias-failure config-failure success skip-eza skip-synth-shell; do
  scenario_directory="${FIXTURE_DIRECTORY}/${scenario}"
  mkdir -p "${scenario_directory}/bin" "${scenario_directory}/home"
  : >"${scenario_directory}/home/.bashrc"
  : >"${scenario_directory}/commands.log"
  setup_arguments=()
  case "${scenario}" in
    skip-eza) setup_arguments=(--skip-eza) ;;
    skip-synth-shell) setup_arguments=(--skip-synth-shell) ;;
    pull-failure|submodule-failure)
      mkdir -p "${scenario_directory}/home/.local/share/synth-shell/.git"
      cp "${FIXTURE_DIRECTORY}/bin/tmux" "${scenario_directory}/home/.local/share/synth-shell/setup.sh"
      ;;
  esac
  scenario_exit_status=0
  env PATH="${scenario_directory}/bin:${FIXTURE_DIRECTORY}/bin" \
    SCENARIO="${scenario}" SCENARIO_DIRECTORY="${scenario_directory}" \
    bash -c '
      source "$1"
      HOME_DIR="${SCENARIO_DIRECTORY}/home"
      BASHRC="${HOME_DIR}/.bashrc"
      TMUX_CONFIG_DIR="${HOME_DIR}/.config/tmux"
      TMUX_CONFIG="${TMUX_CONFIG_DIR}/tmux.conf"
      SYNTH_DIR="${HOME_DIR}/.local/share/synth-shell"
      if [[ "${SCENARIO}" == config-failure ]]; then
        PROJECT_DIR="${SCENARIO_DIRECTORY}/missing-project"
      fi
      main "${@:2}"
    ' setup-test "${SETUP_SCRIPT}" "${setup_arguments[@]}" \
    >"${scenario_directory}/output.log" 2>&1 || scenario_exit_status=$?

  if [[ "${scenario}" == config-failure ]]; then
    [[ "${scenario_exit_status}" != 0 ]] || fail 'missing config accepted'
    [[ ! -s "${scenario_directory}/commands.log" ]] || fail 'provisioning ran after config failure'
    printf '[setup-test] ok: configuration failure remains fatal\n'
    continue
  fi
  [[ "${scenario_exit_status}" == 0 ]] || fail "${scenario}: setup aborted"

  [[ -f "${scenario_directory}/home/.config/tmux/tmux.conf" ]] || fail 'configuration missing'
  grep -q 'reload shell customizations' "${scenario_directory}/output.log" || fail 'setup did not finish'
  case "${scenario}" in
    missing-package|update-failure|both-fail|skip-eza|alias-failure)
      [[ ! -s "${scenario_directory}/home/.bashrc" ]] || fail 'aliases added without eza'
      ;;
    *) grep -q '^# >>> beck tmux eza integration >>>$' "${scenario_directory}/home/.bashrc" || fail 'available eza not integrated' ;;
  esac
  case "${scenario}" in
    success|skip-eza|skip-synth-shell)
      if grep -q 'optional step(s) failed' "${scenario_directory}/output.log"; then
        fail 'successful or skipped step reported as a failure'
      fi
      ;;
    *) grep -q 'optional step(s) failed' "${scenario_directory}/output.log" || fail 'failure summary missing' ;;
  esac
  case "${scenario}" in
    missing-package|update-failure|success|skip-eza)
      grep -q 'run .*setup.sh interactively' "${scenario_directory}/output.log" || fail 'synth-shell download did not finish'
      ;;
    clone-failure|pull-failure|submodule-failure|both-fail|missing-installer)
      if grep -q 'synth-shell is downloaded' "${scenario_directory}/output.log"; then
        fail 'failed synth-shell step claimed success'
      fi
      ;;
  esac
  case "${scenario}" in
    update-failure) forbidden_command='^apt install' ;;
    pull-failure) forbidden_command='^git .* submodule' ;;
    skip-eza) forbidden_command='^apt ' ;;
    skip-synth-shell) forbidden_command='^git ' ;;
    *) forbidden_command='^unexpected-command$' ;;
  esac
  if grep -q "${forbidden_command}" "${scenario_directory}/commands.log"; then
    fail "${scenario}: dependent or skipped operation ran"
  fi
  printf '[setup-test] ok: %s\n' "${scenario}"
done
