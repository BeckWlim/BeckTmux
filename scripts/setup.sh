#!/usr/bin/env bash

# Install the optional terminal pieces used by Beck tmux.
# The script is deliberately idempotent: reuse existing installs and preserve
# shell customizations while repairing the known synth-shell separator bug.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HOME_DIR="${HOME:?HOME must be set}"
BASHRC="${HOME_DIR}/.bashrc"
TMUX_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}/tmux"
TMUX_CONFIG="${TMUX_CONFIG_DIR}/tmux.conf"
SYNTH_DIR="${HOME_DIR}/.local/share/synth-shell"
OVERWRITE_CONFIG=0
SKIP_EZA=0
SKIP_SYNTH_SHELL=0
OPTIONAL_FAILURES=0

info() { printf '[tmux-setup] %s\n' "$*"; }
warn() { printf '[tmux-setup] warning: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: setup.sh [--overwrite] [--skip-eza] [--skip-synth-shell]

Options:
  --overwrite        replace tmux.conf after making a timestamped backup
  --skip-eza         skip eza installation and alias changes
  --skip-synth-shell  skip synth-shell installation and separator repair
  -h, --help         show this help
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --overwrite) OVERWRITE_CONFIG=1 ;;
      --skip-eza) SKIP_EZA=1 ;;
      --skip-synth-shell) SKIP_SYNTH_SHELL=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; return 2 ;;
    esac
    shift
  done
}

run_optional_step() {
  local step_name="$1"
  shift
  # Functions called in a conditional cannot rely on errexit. Each operation
  # inside an optional step must explicitly return on failure.
  if "$@"; then
    return 0
  else
    local step_exit_status="$?"
    OPTIONAL_FAILURES=$((OPTIONAL_FAILURES + 1))
    warn "${step_name} failed (exit ${step_exit_status}); continuing with the remaining setup steps"
  fi
}

install_tmux_config() {
  local source_config="${PROJECT_DIR}/tmux.conf"
  [[ -f "${source_config}" ]] || { warn "project config not found at ${source_config}"; return 1; }

  mkdir -p "${TMUX_CONFIG_DIR}"
  if [[ -e "${TMUX_CONFIG}" && "${source_config}" -ef "${TMUX_CONFIG}" ]]; then
    info "using project config in place: ${TMUX_CONFIG}"
    return
  fi
  if [[ -e "${TMUX_CONFIG}" && "${OVERWRITE_CONFIG}" -ne 1 ]]; then
    warn "existing ${TMUX_CONFIG} preserved (pass --overwrite to replace it)"
    return
  fi
  if [[ -e "${TMUX_CONFIG}" ]]; then
    local backup_path="${TMUX_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "${TMUX_CONFIG}" "${backup_path}"
    info "backed up existing config to ${backup_path}"
  fi
  cp -p "${source_config}" "${TMUX_CONFIG}"
  info "installed ${TMUX_CONFIG}"
}

install_eza() {
  if command -v eza >/dev/null 2>&1; then
    info "eza already installed: $(command -v eza)"
    return
  fi

  if command -v apt-get >/dev/null 2>&1; then
    info 'installing eza with apt'
    if command -v sudo >/dev/null 2>&1; then
      sudo apt-get update || return $?
      sudo apt-get install -y eza || return $?
    else
      apt-get update || return $?
      apt-get install -y eza || return $?
    fi
  elif command -v dnf >/dev/null 2>&1; then
    info 'installing eza with dnf'
    sudo dnf install -y eza || return $?
  elif command -v pacman >/dev/null 2>&1; then
    info 'installing eza with pacman'
    sudo pacman -S --needed --noconfirm eza || return $?
  elif command -v brew >/dev/null 2>&1; then
    info 'installing eza with Homebrew'
    brew install eza || return $?
  else
    warn 'no supported package manager found for eza; install it manually'
    return 1
  fi
}

install_synth_shell() {
  if [[ -f "${HOME_DIR}/.config/synth-shell/synth-shell-prompt.sh" ]]; then
    info 'synth-shell already configured in ~/.config/synth-shell'
    return
  fi

  if ! command -v git >/dev/null 2>&1; then
    warn 'git is required to install synth-shell'
    return 1
  fi

  mkdir -p "$(dirname -- "${SYNTH_DIR}")" || return $?
  if [[ ! -d "${SYNTH_DIR}/.git" ]]; then
    info "cloning synth-shell into ${SYNTH_DIR}"
    git clone --recursive https://github.com/andresgongora/synth-shell.git "${SYNTH_DIR}" || return $?
  else
    info 'updating existing synth-shell checkout'
    git -C "${SYNTH_DIR}" pull --ff-only || return $?
    git -C "${SYNTH_DIR}" submodule update --init --recursive || return $?
  fi

  if [[ ! -x "${SYNTH_DIR}/setup.sh" ]]; then
    warn "synth-shell installer is missing or not executable: ${SYNTH_DIR}/setup.sh"
    return 1
  fi
  if [[ -t 0 && -t 1 ]]; then
    info 'starting synth-shell interactive installer'
    (cd "${SYNTH_DIR}" && ./setup.sh) || return $?
  else
    warn "synth-shell is downloaded; run ${SYNTH_DIR}/setup.sh interactively to select features"
  fi
}

patch_synth_shell_prompt() {
  local prompt_script="${HOME_DIR}/.config/synth-shell/synth-shell-prompt.sh"
  [[ -f "${prompt_script}" ]] || return 0

  # Match only the known broken statement; leave upstream and custom renderers
  # alone. %s must remain in use for prompt text such as directory names.
  local broken_statement='printf '\''%s'\'' "${text_format}${segment_padding}${text}${segment_padding}${separator_padding_left}${separator_format}${separator_char}${separator_padding_right}${no_color}"'
  local fixed_statement='printf '\''%s%b%s'\'' "${text_format}${segment_padding}${text}${segment_padding}${separator_padding_left}${separator_format}" "$separator_char" "${separator_padding_right}${no_color}"'
  grep -Fq "${broken_statement}" "${prompt_script}" || return 0

  local patched_script
  patched_script="$(mktemp "${prompt_script}.patch.XXXXXXXX")" || return $?
  if ! awk -v broken="${broken_statement}" -v fixed="${fixed_statement}" '
    {
      statement = $0
      sub(/^[ \t]*/, "", statement)
      sub(/[ \t]*$/, "", statement)
      if (statement == broken) {
        match($0, /[^ \t]/)
        print substr($0, 1, RSTART - 1) fixed
        replacements++
      } else {
        print
      }
    }
    END { if (replacements != 1) exit 1 }
  ' "${prompt_script}" >"${patched_script}" || ! bash -n "${patched_script}"; then
    rm -f -- "${patched_script}"
    warn 'synth-shell separator repair could not be validated; original script preserved'
    return 1
  fi

  local backup_path
  backup_path="$(mktemp "${prompt_script}.bak.XXXXXXXX")" || {
    rm -f -- "${patched_script}"
    return 1
  }
  local patch_exit_status=0
  cp -p "${prompt_script}" "${backup_path}" && \
    cp "${patched_script}" "${prompt_script}" || patch_exit_status=$?
  rm -f -- "${patched_script}"
  [[ "${patch_exit_status}" == 0 ]] || return "${patch_exit_status}"
  info "repaired synth-shell Unicode separators; backup: ${backup_path}"
}

wire_eza_aliases() {
  [[ -f "${BASHRC}" ]] || return 0
  command -v eza >/dev/null 2>&1 || return 0

  local marker='# >>> beck tmux eza integration >>>'
  if grep -Eq "^[[:space:]]*alias[[:space:]]+ls=['\"]eza[[:space:]]" "${BASHRC}" 2>/dev/null; then
    info 'eza aliases already configured in ~/.bashrc'
    return
  fi
  grep -Fqx "${marker}" "${BASHRC}" 2>/dev/null && {
    info 'eza aliases already present in ~/.bashrc'
    return
  }

  info 'adding guarded eza aliases to ~/.bashrc'
  cat >>"${BASHRC}" <<'EOF' || return $?

# >>> beck tmux eza integration >>>
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --icons=auto --git --group-directories-first'
  alias l='eza --icons=auto --git --group-directories-first'
  alias ll='eza -l --icons=auto --git --group-directories-first'
  alias la='eza -a --icons=auto --git --group-directories-first'
  alias lt='eza --tree --level=2 --icons=auto'
fi
# <<< beck tmux eza integration <<<
EOF
}

main() {
  parse_args "$@"
  install_tmux_config
  command -v tmux >/dev/null 2>&1 || warn 'tmux is not installed'
  if ((SKIP_EZA == 0)); then
    run_optional_step 'eza installation' install_eza
  fi
  if ((SKIP_SYNTH_SHELL == 0)); then
    run_optional_step 'synth-shell installation' install_synth_shell
    run_optional_step 'synth-shell separator repair' patch_synth_shell_prompt
  fi
  if ((SKIP_EZA == 0)); then
    run_optional_step 'eza aliases' wire_eza_aliases
  fi
  if ((OPTIONAL_FAILURES > 0)); then
    warn "setup completed with ${OPTIONAL_FAILURES} optional step(s) failed; see warnings above"
  fi
  info "configuration: ${PROJECT_DIR}/tmux.conf"
  info 'reload an attached server with: C-a R'
  info 'reload shell customizations with: source ~/.bashrc'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
