#!/usr/bin/env bash

# Fake external installers; never provision packages or edit the user's shell.
set -Eeuo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SETUP_SCRIPT="${TEST_DIRECTORY}/../scripts/setup.sh"
readonly FIXTURE_DIRECTORY="$(mktemp -d /tmp/beck-setup-tests.XXXXXXXX)"
trap 'rm -rf -- "${FIXTURE_DIRECTORY}"' EXIT

fail() { printf '[setup-test] FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "${FIXTURE_DIRECTORY}/bin"
for utility in bash dirname mkdir cp date grep sh tar mktemp rm chmod env; do
  ln -s "$(command -v "${utility}")" "${FIXTURE_DIRECTORY}/bin/${utility}"
done
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "${FIXTURE_DIRECTORY}/bin/python3"

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
    [[ "${SCENARIO}" != missing-package ]] || exit 100
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
exit 99
EOF
chmod +x "${FIXTURE_DIRECTORY}/bin/"{apt-get,sudo,tmux,git,cat}

cat >"${FIXTURE_DIRECTORY}/bin/starship-template" <<'EOF'
#!/usr/bin/env bash
[[ "${1-}" != init ]] || printf 'export BECK_STARSHIP_INIT=1\n'
EOF
cat >"${FIXTURE_DIRECTORY}/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${SCENARIO_DIRECTORY}/commands.log"
[[ "${SCENARIO}" != prompt-download-failure ]] || exit 22
while (($#)); do
  if [[ "$1" == --output ]]; then
    installer_output="$2"
    break
  fi
  shift
done
printf '%s\n' "${installer_output%/install.sh}" >"${SCENARIO_DIRECTORY}/download-dir"
/bin/cat >"${installer_output}" <<'INSTALLER'
#!/bin/sh
printf 'installer %s\n' "$*" >>"${SCENARIO_DIRECTORY}/commands.log"
[ "${SCENARIO}" != prompt-installer-failure ] || exit 55
[ "$1" = --yes ] && [ "$2" = --bin-dir ] || exit 99
[ "${SCENARIO}" != prompt-missing-binary ] || exit 0
cp "${SCENARIO_DIRECTORY}/../bin/starship-template" "$3/starship"
INSTALLER
EOF
chmod +x "${FIXTURE_DIRECTORY}/bin/"{starship-template,curl}

for scenario in missing-package update-failure alias-failure config-failure success core-only core-existing-eza core-no-bashrc eza-no-bashrc existing-eza existing-aliases existing-config overwrite-config; do
  scenario_directory="${FIXTURE_DIRECTORY}/${scenario}"
  mkdir -p "${scenario_directory}/bin" "${scenario_directory}/home"
  : >"${scenario_directory}/home/.bashrc"
  : >"${scenario_directory}/commands.log"
  setup_arguments=(--eza)
  case "${scenario}" in
    core-only) setup_arguments=() ;;
    core-existing-eza)
      setup_arguments=()
      cp "${FIXTURE_DIRECTORY}/bin/tmux" "${scenario_directory}/bin/eza"
      ;;
    core-no-bashrc)
      setup_arguments=()
      rm "${scenario_directory}/home/.bashrc"
      ;;
    eza-no-bashrc) rm "${scenario_directory}/home/.bashrc" ;;
    existing-eza)
      cp "${FIXTURE_DIRECTORY}/bin/tmux" "${scenario_directory}/bin/eza"
      ;;
    existing-aliases)
      printf "alias ls='eza --icons=auto'\n" >"${scenario_directory}/home/.bashrc"
      cp "${scenario_directory}/home/.bashrc" "${scenario_directory}/original.bashrc"
      ;;
    existing-config|overwrite-config)
      mkdir -p "${scenario_directory}/home/.config/tmux"
      printf '# user configuration\n' >"${scenario_directory}/home/.config/tmux/tmux.conf"
      [[ "${scenario}" != overwrite-config ]] || setup_arguments+=(--overwrite)
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
  if [[ "${scenario}" != existing-config ]]; then
    for helper_script in theme.sh clipboard.sh; do
      cmp -s "${TEST_DIRECTORY}/../scripts/${helper_script}" \
        "${scenario_directory}/home/.config/tmux/scripts/${helper_script}" || fail "runtime helper missing: ${helper_script}"
    done
  fi
  grep -q 'reload shell customizations' "${scenario_directory}/output.log" || fail 'setup did not finish'
  case "${scenario}" in
    missing-package|update-failure|core-only|core-existing-eza|core-no-bashrc|alias-failure)
      [[ ! -s "${scenario_directory}/home/.bashrc" ]] || fail 'aliases added without eza'
      ;;
    existing-aliases)
      cmp -s "${scenario_directory}/home/.bashrc" "${scenario_directory}/original.bashrc" || fail 'existing aliases changed'
      ;;
    *) grep -q '^# >>> beck tmux eza integration >>>$' "${scenario_directory}/home/.bashrc" || fail 'available eza not integrated' ;;
  esac
  case "${scenario}" in
    success|core-only|core-existing-eza|core-no-bashrc|eza-no-bashrc|existing-eza|existing-aliases|existing-config|overwrite-config)
      if grep -q 'optional step(s) failed' "${scenario_directory}/output.log"; then
        fail 'successful or skipped step reported as a failure'
      fi
      ;;
    *) grep -q 'optional step(s) failed' "${scenario_directory}/output.log" || fail 'failure summary missing' ;;
  esac
  case "${scenario}" in
    update-failure) forbidden_command='^apt install' ;;
    core-only|core-existing-eza|core-no-bashrc|existing-eza) forbidden_command='^apt ' ;;
    *) forbidden_command='^unexpected-command$' ;;
  esac
  if grep -q '^git ' "${scenario_directory}/commands.log"; then
    fail "${scenario}: setup invoked an unrelated Git operation"
  fi
  case "${scenario}" in
    core-only|core-existing-eza|core-no-bashrc)
      [[ ! -s "${scenario_directory}/commands.log" ]] || fail 'core setup ran optional provisioning'
      [[ ! -d "${scenario_directory}/home/.config/tmux/shell" ]] || fail 'core setup installed shell integrations'
      [[ ! -d "${scenario_directory}/home/.config/tmux/plugins" ]] || fail 'core setup installed optional plugins'
      if [[ "${scenario}" == core-no-bashrc ]]; then
        [[ ! -e "${scenario_directory}/home/.bashrc" ]] || fail 'core setup created Bash configuration'
      fi
      ;;
    existing-config)
      grep -qx '# user configuration' "${scenario_directory}/home/.config/tmux/tmux.conf" || fail 'existing config overwritten'
      ;;
    overwrite-config)
      cmp -s "${TEST_DIRECTORY}/../tmux.conf" "${scenario_directory}/home/.config/tmux/tmux.conf" || fail 'replacement config missing'
      config_backups=("${scenario_directory}/home/.config/tmux/"tmux.conf.bak.*)
      [[ ${#config_backups[@]} == 1 ]] || fail 'config backup missing'
      grep -qx '# user configuration' "${config_backups[0]}" || fail 'original config not backed up'
      ;;
    success)
      env PATH="${scenario_directory}/bin:${FIXTURE_DIRECTORY}/bin" \
        HOME="${scenario_directory}/home" XDG_CONFIG_HOME="${scenario_directory}/home/.config" \
        SCENARIO="${scenario}" SCENARIO_DIRECTORY="${scenario_directory}" \
        bash "${SETUP_SCRIPT}" --eza >"${scenario_directory}/repeat.log" 2>&1 || fail 'repeat setup aborted'
      [[ $(grep -c '^# >>> beck tmux eza integration >>>$' "${scenario_directory}/home/.bashrc") == 1 ]] || fail 'repeat setup duplicated aliases'
      [[ $(wc -l <"${scenario_directory}/commands.log") == 2 ]] || fail 'repeat setup reinstalled eza'
      ;;
  esac
  if grep -q "${forbidden_command}" "${scenario_directory}/commands.log"; then
    fail "${scenario}: dependent or skipped operation ran"
  fi
  printf '[setup-test] ok: %s\n' "${scenario}"
done

# Exercise the real setup entry point and prompt deployment with a fake download.
for scenario in prompt-install prompt-existing prompt-local prompt-download-failure prompt-installer-failure prompt-missing-binary prompt-configuration-failure; do
  scenario_directory="${FIXTURE_DIRECTORY}/${scenario}"
  mkdir -p "${scenario_directory}/bin" "${scenario_directory}/home" "${scenario_directory}/project/scripts"
  : >"${scenario_directory}/commands.log"
  cat >"${scenario_directory}/home/.bashrc" <<'EOF'
alias keep_me=true
# >>> beck tmux Bash completion >>>
:
# <<< beck tmux Bash completion <<<
EOF
  if [[ "${scenario}" == prompt-configuration-failure ]]; then
    printf 'if\n' >"${scenario_directory}/home/.bashrc"
  fi
  cp "${scenario_directory}/home/.bashrc" "${scenario_directory}/original.bashrc"
  cp "${TEST_DIRECTORY}/../tmux.conf" "${scenario_directory}/project/"
  cp -R "${TEST_DIRECTORY}/../shell" "${scenario_directory}/project/"
  for setup_script in setup.sh theme.sh clipboard.sh; do
    cp "${TEST_DIRECTORY}/../scripts/${setup_script}" "${scenario_directory}/project/scripts/"
  done
  case "${scenario}" in
    prompt-existing)
      cp "${FIXTURE_DIRECTORY}/bin/starship-template" "${scenario_directory}/bin/starship"
      ;;
    prompt-local)
      mkdir -p "${scenario_directory}/home/.local/bin"
      cp "${FIXTURE_DIRECTORY}/bin/starship-template" "${scenario_directory}/home/.local/bin/starship"
      ;;
  esac
  env PATH="${scenario_directory}/bin:${FIXTURE_DIRECTORY}/bin" \
    HOME="${scenario_directory}/home" XDG_CONFIG_HOME="${scenario_directory}/home/.config" \
    SCENARIO="${scenario}" SCENARIO_DIRECTORY="${scenario_directory}" \
    bash -c '
      source "$1"
      setup_completion() { printf "optional completion\n" >>"${SCENARIO_DIRECTORY}/commands.log"; }
      setup_clipboard() { printf "optional clipboard\n" >>"${SCENARIO_DIRECTORY}/commands.log"; }
      main --prompt --completion --clipboard
    ' setup-test "${scenario_directory}/project/scripts/setup.sh" \
    >"${scenario_directory}/output.log" 2>&1 || fail "${scenario}: setup aborted"
  for optional_script in completion clipboard; do
    grep -qx "optional ${optional_script}" "${scenario_directory}/commands.log" || fail "${scenario}: other optional step skipped"
  done
  case "${scenario}" in
    prompt-install|prompt-existing|prompt-local)
      grep -qx 'alias keep_me=true' "${scenario_directory}/home/.bashrc" || fail 'custom alias removed'
      cmp -s "${TEST_DIRECTORY}/../shell/starship.toml" "${scenario_directory}/home/.config/tmux/shell/starship.toml" || fail 'Starship config missing'
      bash -n "${scenario_directory}/home/.bashrc"
      if grep -q 'optional step(s) failed' "${scenario_directory}/output.log"; then
        cat "${scenario_directory}/output.log" >&2
        fail "${scenario}: prompt setup reported failure"
      fi
      ;;
    *)
      cmp -s "${scenario_directory}/home/.bashrc" "${scenario_directory}/original.bashrc" || fail 'failed prompt step changed Bash configuration'
      grep -q 'optional step(s) failed' "${scenario_directory}/output.log" || fail 'prompt failure not summarized'
      ;;
  esac
  case "${scenario}" in
    prompt-install)
      grep -qx "installer --yes --bin-dir ${scenario_directory}/home/.local/bin" "${scenario_directory}/commands.log" || fail 'installer did not target user bin directory'
      env PATH="${scenario_directory}/bin:${FIXTURE_DIRECTORY}/bin" \
        HOME="${scenario_directory}/home" XDG_CONFIG_HOME="${scenario_directory}/home/.config" \
        SCENARIO="${scenario}" SCENARIO_DIRECTORY="${scenario_directory}" \
        bash "${scenario_directory}/project/scripts/setup.sh" --prompt \
        >"${scenario_directory}/repeat.log" 2>&1 || fail 'repeat prompt setup aborted'
      [[ $(grep -c '^curl ' "${scenario_directory}/commands.log") == 1 ]] || fail 'repeat setup downloaded Starship again'
      [[ $(grep -c '^# >>> beck tmux Bash prompt >>>$' "${scenario_directory}/home/.bashrc") == 1 ]] || fail 'repeat setup duplicated prompt loader'
      prompt_backups=("${scenario_directory}/home/".bashrc.bak.*)
      [[ ${#prompt_backups[@]} == 1 ]] || fail 'repeat setup made unnecessary Bash backups'
      cmp -s "${prompt_backups[0]}" "${scenario_directory}/original.bashrc" || fail 'Bash backup differs from original'
      ;;
    prompt-existing|prompt-local)
      if grep -q '^curl ' "${scenario_directory}/commands.log"; then
        fail 'installed Starship was downloaded again'
      fi
      ;;
  esac
  if [[ -f "${scenario_directory}/download-dir" ]]; then
    [[ ! -e $(<"${scenario_directory}/download-dir") ]] || fail 'installer temporary directory leaked'
  fi
  if [[ "${scenario}" == prompt-local ]]; then
    env PATH="${FIXTURE_DIRECTORY}/bin" HOME="${scenario_directory}/home" \
      XDG_CONFIG_HOME="${scenario_directory}/home/.config" \
      bash --noprofile --norc -ic 'source "$1"; [[ ${BECK_STARSHIP_INIT-} == 1 ]]' \
      prompt-test "${scenario_directory}/home/.config/tmux/shell/prompt.bash" \
      >"${scenario_directory}/runtime.log" 2>&1 || fail 'new shell did not find user-local Starship'
  fi
  printf '[setup-test] ok: %s\n' "${scenario}"
done
