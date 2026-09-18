#!/usr/bin/env bash

# Fake external installers; never provision packages or edit the user's shell.
set -Eeuo pipefail

readonly TEST_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SETUP_SCRIPT="${TEST_DIRECTORY}/../scripts/setup.sh"
readonly FIXTURE_DIRECTORY="$(mktemp -d /tmp/beck-setup-tests.XXXXXXXX)"
trap 'rm -rf -- "${FIXTURE_DIRECTORY}"' EXIT

fail() { printf '[setup-test] FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "${FIXTURE_DIRECTORY}/bin"
for utility in bash dirname mkdir cp date grep awk mktemp rm; do
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

# Exercise the installed-script repair without downloading or installing tools.
utf8_locale="$(locale -a | awk 'tolower($0) ~ /utf-?8/ { print; exit }')"
[[ -n "${utf8_locale}" ]] || fail 'a UTF-8 locale is required for separator tests'

for synth_scenario in broken fixed upstream custom duplicate invalid skip; do
  synth_directory="${FIXTURE_DIRECTORY}/synth-${synth_scenario}"
  prompt_directory="${synth_directory}/home/.config/synth-shell"
  prompt_script="${prompt_directory}/synth-shell-prompt.sh"
  mkdir -p "${prompt_directory}"
  : >"${synth_directory}/commands.log"
  cat >"${prompt_directory}/synth-shell-prompt.config" <<'EOF'
separator_char='\uE0B0'
segment_padding=' '
separator_padding_left=''
separator_padding_right=''
EOF
  cat >"${prompt_script}" <<'EOF'
printSegment() {
  local text=$1
  local text_format='' separator_format='' no_color=''
EOF
  case "${synth_scenario}" in
    fixed)
      cat >>"${prompt_script}" <<'EOF'
  printf '%s%b%s' "${text_format}${segment_padding}${text}${segment_padding}${separator_padding_left}${separator_format}" "$separator_char" "${separator_padding_right}${no_color}"
EOF
      ;;
    upstream)
      cat >>"${prompt_script}" <<'EOF'
  printf "${text_format}${segment_padding}${text}${segment_padding}${separator_padding_left}${separator_format}${separator_char}${separator_padding_right}${no_color}"
EOF
      ;;
    custom) printf '  printf "%%s" "$separator_char"\n' >>"${prompt_script}" ;;
    *)
      cat >>"${prompt_script}" <<'EOF'
  printf '%s' "${text_format}${segment_padding}${text}${segment_padding}${separator_padding_left}${separator_format}${separator_char}${separator_padding_right}${no_color}"
EOF
      ;;
  esac
  printf '}\n' >>"${prompt_script}"
  if [[ "${synth_scenario}" == duplicate ]]; then
    cat "${prompt_script}" >"${synth_directory}/duplicate.sh"
    cat "${synth_directory}/duplicate.sh" >>"${prompt_script}"
  elif [[ "${synth_scenario}" == invalid ]]; then
    printf 'if\n' >>"${prompt_script}"
  fi
  chmod 750 "${prompt_script}"
  cp -p "${prompt_script}" "${synth_directory}/original.sh"
  cp "${prompt_directory}/synth-shell-prompt.config" "${synth_directory}/original.config"
  synth_arguments=(--skip-eza)
  [[ "${synth_scenario}" != skip ]] || synth_arguments+=(--skip-synth-shell)

  # Run twice: a repaired installation must not be patched or backed up again.
  for setup_run in 1 2; do
    env PATH="${FIXTURE_DIRECTORY}/bin" HOME="${synth_directory}/home" \
      XDG_CONFIG_HOME="${synth_directory}/home/.config" \
      SCENARIO="synth-${synth_scenario}" SCENARIO_DIRECTORY="${synth_directory}" \
      bash "${SETUP_SCRIPT}" "${synth_arguments[@]}" \
      >"${synth_directory}/output-${setup_run}.log" 2>&1 || fail "${synth_scenario}: setup aborted"
  done
  [[ ! -s "${synth_directory}/commands.log" ]] || fail 'existing synth-shell triggered provisioning'
  cmp -s "${prompt_directory}/synth-shell-prompt.config" "${synth_directory}/original.config" || \
    fail 'separator configuration changed'
  shopt -s nullglob
  synth_backups=("${prompt_script}".bak.*)
  synth_temporary_files=("${prompt_script}".patch.*)
  shopt -u nullglob
  [[ ${#synth_temporary_files[@]} == 0 ]] || fail 'temporary patch file leaked'

  if [[ "${synth_scenario}" == broken ]]; then
    [[ ${#synth_backups[@]} == 1 ]] || fail 'repair did not create exactly one backup'
    cmp -s "${synth_backups[0]}" "${synth_directory}/original.sh" || fail 'backup differs from original'
    [[ $(stat -c '%a' "${prompt_script}" 2>/dev/null || stat -f '%Lp' "${prompt_script}") == 750 ]] || \
      fail 'script permissions changed'
    if grep -q 'repaired synth-shell' "${synth_directory}/output-2.log"; then
      fail 'second setup repeated the repair'
    fi
    literal_prompt_text='directory %s \n \u0041'
    rendered_segment="$(env LC_ALL="${utf8_locale}" bash -c '
      source "$1"
      source "$2"
      printSegment "$3"
    ' separator-test "${prompt_script}" "${prompt_directory}/synth-shell-prompt.config" "${literal_prompt_text}")"
    expected_triangle="$(env LC_ALL="${utf8_locale}" bash -c "printf '\\uE0B0'")"
    [[ "${rendered_segment}" == " ${literal_prompt_text} ${expected_triangle}" ]] || \
      fail 'separator conversion changed literal prompt text or failed to produce the triangle'
    ascii_segment="$(env LC_ALL="${utf8_locale}" bash -c '
      source "$1"
      source "$2"
      separator_char=">"
      printSegment "$3"
    ' separator-test "${prompt_script}" "${prompt_directory}/synth-shell-prompt.config" "${literal_prompt_text}")"
    [[ "${ascii_segment}" == " ${literal_prompt_text} >" ]] || fail 'ASCII separator compatibility'
  else
    cmp -s "${prompt_script}" "${synth_directory}/original.sh" || fail "${synth_scenario}: original script changed"
    [[ ${#synth_backups[@]} == 0 ]] || fail "${synth_scenario}: unnecessary backup"
  fi
  case "${synth_scenario}" in
    duplicate|invalid)
      grep -q 'optional step(s) failed' "${synth_directory}/output-1.log" || fail 'patch failure not reported'
      ;;
    *)
      if grep -q 'optional step(s) failed' "${synth_directory}/output-1.log"; then
        fail "${synth_scenario}: unexpected optional failure"
      fi
      ;;
  esac
  printf '[setup-test] ok: synth-shell %s\n' "${synth_scenario}"
done
