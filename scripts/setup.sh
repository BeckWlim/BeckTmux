#!/usr/bin/env bash

# Install the optional terminal pieces used by Beck tmux.
# The script is deliberately idempotent: reuse existing installs and preserve
# shell customizations.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HOME_DIR="${HOME:?HOME must be set}"
BASHRC="${HOME_DIR}/.bashrc"
TMUX_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}/tmux"
TMUX_CONFIG="${TMUX_CONFIG_DIR}/tmux.conf"
OVERWRITE_CONFIG=0
ENABLE_EZA=0
ENABLE_PROMPT=0
ENABLE_COMPLETION=0
COMPLETION_NO_INSTALL=0
ENABLE_CLIPBOARD=0
CLIPBOARD_LOCAL_RUNTIME=0
CLIPBOARD_AUTOSTART=1
OPTIONAL_FAILURES=0
PROMPT_PROJECT_DIR="${PROJECT_DIR}"
PROMPT_CONFIG_DIR="${TMUX_CONFIG_DIR}/shell"
PROMPT_BASHRC="${BASHRC}"
COMPLETION_PROJECT_DIR="${PROJECT_DIR}"
COMPLETION_CONFIG_DIR="${TMUX_CONFIG_DIR}/shell"
COMPLETION_DATA_DIR="${XDG_DATA_HOME:-${HOME_DIR}/.local/share}"
COMPLETION_BASHRC="${BASHRC}"

info() { printf '[tmux-setup] %s\n' "$*"; }
warn() { printf '[tmux-setup] warning: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: setup.sh [--overwrite] [--eza] [--prompt] [--completion] [--clipboard]

With no feature flags, install only the BeckTmux configuration and runtime helpers.
The tmux binary must already be installed; setup checks for it without upgrading it.

Options:
  --overwrite        replace tmux.conf after making a timestamped backup
  --eza              install eza and configure directory-listing aliases
  --prompt           install Starship and configure the Beck Bash prompt
  --completion       install and configure enhanced Bash Tab completion
  --clipboard        install system clipboard history (local Linux desktop)
  --completion-no-install  configure installed ble.sh without downloading it
  --clipboard-local-runtime  extract clipboard packages locally instead of using sudo
  --no-autostart     skip the clipboard desktop autostart entry
  -h, --help         show this help
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --overwrite) OVERWRITE_CONFIG=1 ;;
      --eza) ENABLE_EZA=1 ;;
      --prompt) ENABLE_PROMPT=1 ;;
      --completion) ENABLE_COMPLETION=1 ;;
      --clipboard) ENABLE_CLIPBOARD=1 ;;
      --completion-no-install) ENABLE_COMPLETION=1; COMPLETION_NO_INSTALL=1 ;;
      --clipboard-local-runtime) ENABLE_CLIPBOARD=1; CLIPBOARD_LOCAL_RUNTIME=1 ;;
      --no-autostart) CLIPBOARD_AUTOSTART=0 ;;
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
  # Keep the configuration's runtime helpers beside it on separate installs.
  mkdir -p "${TMUX_CONFIG_DIR}/scripts"
  local helper_script
  for helper_script in theme.sh clipboard.sh; do
    cp -p "${PROJECT_DIR}/scripts/${helper_script}" "${TMUX_CONFIG_DIR}/scripts/${helper_script}"
  done
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

install_starship() {
  if command -v starship >/dev/null 2>&1; then
    info "Starship already installed: $(command -v starship)"
    return
  fi

  local starship_bin_dir="${HOME_DIR}/.local/bin"
  if [[ ! -x "${starship_bin_dir}/starship" ]]; then
    (
      local starship_dependency starship_download_dir
      for starship_dependency in curl sh tar; do
        command -v "${starship_dependency}" >/dev/null 2>&1 || {
          warn "${starship_dependency} is required to install Starship"
          exit 1
        }
      done
      starship_download_dir="$(mktemp -d "${TMPDIR:-/tmp}/beck-starship.XXXXXXXX")" || exit $?
      trap 'rm -rf -- "${starship_download_dir}"' EXIT
      mkdir -p "${starship_bin_dir}" || exit $?
      info "installing Starship in ${starship_bin_dir}"
      curl --fail --location --retry 2 https://starship.rs/install.sh \
        --output "${starship_download_dir}/install.sh" || exit $?
      sh "${starship_download_dir}/install.sh" --yes --bin-dir "${starship_bin_dir}"
    ) || return $?
  fi
  export PATH="${starship_bin_dir}:${PATH}"
  command -v starship >/dev/null 2>&1 || {
    warn 'Starship installer did not provide an executable'
    return 1
  }
}

setup_starship_prompt() {
  command -v python3 >/dev/null 2>&1 || {
    warn 'Python 3 is required to configure the Starship prompt'
    return 1
  }
  install_starship || return $?
  configure_prompt
}

configure_prompt() {
  local prompt_file prompt_target
  mkdir -p "${PROMPT_CONFIG_DIR}" || return $?
  for prompt_file in prompt.bash starship.toml; do
    prompt_target="${PROMPT_CONFIG_DIR}/${prompt_file}"
    if [[ ! -e ${prompt_target} || ! ${PROMPT_PROJECT_DIR}/shell/${prompt_file} -ef ${prompt_target} ]]; then
      if [[ -e ${prompt_target} ]] && ! cmp -s "${PROMPT_PROJECT_DIR}/shell/${prompt_file}" "${prompt_target}"; then
        local prompt_backup
        prompt_backup=$(mktemp "${prompt_target}.bak.XXXXXXXX") || return $?
        cp -p "${prompt_target}" "${prompt_backup}" || return $?
      fi
      cp -p "${PROMPT_PROJECT_DIR}/shell/${prompt_file}" "${prompt_target}" || return $?
    fi
  done

  python3 - "${PROMPT_BASHRC}" <<'PY'
import pathlib
import shutil
import subprocess
import sys
import tempfile

bashrc = pathlib.Path(sys.argv[1])
original = bashrc.read_text() if bashrc.exists() else ''
text = original
marker = '# >>> beck tmux Bash prompt >>>'
if marker not in text:
    block = '''# >>> beck tmux Bash prompt >>>
if [[ $- == *i* && -r "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/shell/prompt.bash" ]]; then
  source "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/shell/prompt.bash"
fi
# <<< beck tmux Bash prompt <<<

'''
    completion_marker = '# >>> beck tmux Bash completion >>>'
    if completion_marker in text:
        text = text.replace(completion_marker, block + completion_marker, 1)
    else:
        text = text.rstrip() + '\n\n' + block
if text != original:
    subprocess.run(['bash', '-n'], input=text, text=True, check=True)
    if bashrc.exists():
        with tempfile.NamedTemporaryFile(prefix=bashrc.name + '.bak.', dir=bashrc.parent, delete=False) as backup:
            backup_path = backup.name
        shutil.copy2(bashrc, backup_path)
        print('[prompt-setup] Bash backup: ' + backup_path)
    bashrc.write_text(text)
print('[prompt-setup] Starship configured; open a new Bash shell to activate')
PY
}

find_ble() {
  local ble_candidate
  for ble_candidate in "${COMPLETION_DATA_DIR}/blesh/ble.sh" \
    /usr/share/blesh/ble.sh /usr/local/share/blesh/ble.sh; do
    [[ ! -r ${ble_candidate} ]] || return 0
  done
  return 1
}

install_ble() (
  local download_directory dependency
  for dependency in curl tar xz; do
    command -v "${dependency}" >/dev/null 2>&1 || {
      printf '[completion-setup] required command missing: %s\n' "${dependency}" >&2
      return 1
    }
  done
  download_directory=$(mktemp -d "${TMPDIR:-/tmp}/beck-blesh.XXXXXXXX") || return $?
  trap 'rm -rf -- "${download_directory}"' EXIT
  info 'downloading the official ble.sh nightly release'
  curl --fail --location --retry 2 \
    https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz \
    --output "${download_directory}/ble-nightly.tar.xz" || return
  tar -xJf "${download_directory}/ble-nightly.tar.xz" -C "${download_directory}" || return
  bash "${download_directory}/ble-nightly/ble.sh" --install "${COMPLETION_DATA_DIR}" || return
  find_ble
)

configure_completion() {
  local source_loader="${COMPLETION_PROJECT_DIR}/shell/completion.bash"
  local target_loader="${COMPLETION_CONFIG_DIR}/completion.bash"
  [[ -r ${source_loader} ]] || { printf 'Missing loader: %s\n' "${source_loader}" >&2; return 1; }
  mkdir -p "${COMPLETION_CONFIG_DIR}" || return $?
  if [[ ! -e ${target_loader} || ! ${source_loader} -ef ${target_loader} ]]; then
    cp -p "${source_loader}" "${target_loader}" || return $?
  fi

  local marker='# >>> beck tmux Bash completion >>>'
  if [[ -f ${COMPLETION_BASHRC} ]] && grep -Fqx "${marker}" "${COMPLETION_BASHRC}"; then
    info 'Bash completion loader already configured'
    return
  fi
  if [[ -e ${COMPLETION_BASHRC} ]]; then
    local backup_path
    backup_path=$(mktemp "${COMPLETION_BASHRC}.bak.XXXXXXXX") || return $?
    cp -p "${COMPLETION_BASHRC}" "${backup_path}" || return $?
    info "saved existing Bash configuration to ${backup_path}"
  fi
  cat >>"${COMPLETION_BASHRC}" <<'EOF' || return $?

# >>> beck tmux Bash completion >>>
if [[ $- == *i* && -r "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/shell/completion.bash" ]]; then
  source "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/shell/completion.bash"
fi
# <<< beck tmux Bash completion <<<
EOF
  info 'added the completion loader to ~/.bashrc'
}

setup_completion() {
  if ! find_ble; then
    if ((COMPLETION_NO_INSTALL)); then
      printf '[completion-setup] ble.sh is not installed; rerun without --completion-no-install\n' >&2
      return 1
    fi
    install_ble || return
  fi
  configure_completion || return $?
  info 'open a new Bash shell to enable the completion setup'
  if ! command -v carapace >/dev/null 2>&1; then
    info 'using Bash programmable completion; install carapace-bin for additional completers and descriptions'
  fi
}

setup_clipboard() (
  local clipboard_plugin_dir="${TMUX_CONFIG_DIR}/plugins/tmux-fzf"
  local clipboard_revision=e5f427e9dcf180ca92e2f8af47ba07f644fd4585
  local clipboard_command clipboard_package_path clipboard_actual_revision
  local clipboard_runtime_dir="${TMUX_CONFIG_DIR}/plugins/clipboard-runtime"
  local clipboard_autostart_dir clipboard_autostart_path
  local -a clipboard_commands=(git fzf copyq) clipboard_packages=(fzf copyq copyq-plugins)
  local -a clipboard_missing_packages=() clipboard_privilege=()
  export PATH="${PATH}:${clipboard_runtime_dir}/usr/bin"

  if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; then
    info 'Skipping desktop clipboard history over SSH; core copying uses OSC 52'
    return 0
  fi

  if ((CLIPBOARD_LOCAL_RUNTIME)); then
    command -v git >/dev/null || { warn 'git is required for clipboard setup'; return 1; }
    mkdir -p "${clipboard_runtime_dir}/packages" || return $?
    (cd "${clipboard_runtime_dir}/packages" && apt-get download "${clipboard_packages[@]}") || return $?
    for clipboard_package_path in "${clipboard_runtime_dir}"/packages/*.deb; do
      dpkg-deb -x "${clipboard_package_path}" "${clipboard_runtime_dir}" || return $?
    done
  else
    for clipboard_command in "${clipboard_commands[@]}"; do
      command -v "${clipboard_command}" >/dev/null || clipboard_missing_packages+=("${clipboard_command}")
    done
    if ((${#clipboard_missing_packages[@]})); then
      command -v apt-get >/dev/null || {
        warn 'Install git, fzf and CopyQ with your package manager'
        return 1
      }
      [[ ${EUID} == 0 ]] || clipboard_privilege=(sudo)
      "${clipboard_privilege[@]}" apt-get update || return $?
      "${clipboard_privilege[@]}" apt-get install -y "${clipboard_missing_packages[@]}" || return $?
    fi
  fi
  for clipboard_command in "${clipboard_commands[@]}"; do
    command -v "${clipboard_command}" >/dev/null || {
      warn "Missing ${clipboard_command}; install it or use --clipboard-local-runtime"
      return 1
    }
  done

  if [[ ! -d "${clipboard_plugin_dir}/.git" ]]; then
    git clone https://github.com/sainnhe/tmux-fzf.git "${clipboard_plugin_dir}" || return $?
    git -C "${clipboard_plugin_dir}" checkout --detach "${clipboard_revision}" || return $?
  fi
  clipboard_actual_revision="$(git -C "${clipboard_plugin_dir}" rev-parse HEAD)" || return $?
  if [[ "${clipboard_actual_revision}" != "${clipboard_revision}" ]]; then
    warn 'Existing clipboard plugin revision differs; preserved it'
    return 1
  fi

  mkdir -p "${TMUX_CONFIG_DIR}/scripts" || return $?
  if [[ ! "${PROJECT_DIR}/scripts/clipboard.sh" -ef "${TMUX_CONFIG_DIR}/scripts/clipboard.sh" ]]; then
    install -m 755 "${PROJECT_DIR}/scripts/clipboard.sh" "${TMUX_CONFIG_DIR}/scripts/clipboard.sh" || return $?
  fi
  cat >"${clipboard_plugin_dir}/scripts/clipboard.sh" <<'ADAPTER' || return $?
#!/usr/bin/env bash
set -Eeuo pipefail
export BECK_TMUX_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec bash "${BECK_TMUX_DIRECTORY}/scripts/clipboard.sh" "$@"
ADAPTER
  chmod +x "${clipboard_plugin_dir}/scripts/clipboard.sh" || return $?
  if ((CLIPBOARD_AUTOSTART)); then
    clipboard_autostart_dir="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}/autostart"
    mkdir -p "${clipboard_autostart_dir}" || return $?
    clipboard_autostart_path="${clipboard_autostart_dir}/beck-clipboard.desktop"
    if [[ ! -e "${clipboard_autostart_path}" ]]; then
      cat >"${clipboard_autostart_path}" <<EOF || return $?
[Desktop Entry]
Type=Application
Name=Beck clipboard history
Exec=bash "${TMUX_CONFIG_DIR}/scripts/clipboard.sh" start
Terminal=false
NoDisplay=true
EOF
    fi
  fi
  info 'Clipboard ready; run clipboard.sh start in your desktop session, then reload with C-s R'
)

wire_eza_aliases() {
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
  if ((ENABLE_EZA)); then
    run_optional_step 'eza installation' install_eza
    run_optional_step 'eza aliases' wire_eza_aliases
  fi
  if ((ENABLE_PROMPT)); then
    run_optional_step 'Starship prompt' setup_starship_prompt
  fi
  if ((ENABLE_COMPLETION)); then
    run_optional_step 'Bash completion' setup_completion
  fi
  if ((ENABLE_CLIPBOARD)); then
    run_optional_step 'system clipboard history' setup_clipboard
  fi
  if ((OPTIONAL_FAILURES > 0)); then
    warn "setup completed with ${OPTIONAL_FAILURES} optional step(s) failed; see warnings above"
  fi
  info "configuration: ${PROJECT_DIR}/tmux.conf"
  info 'reload an attached server with: C-s R'
  info 'reload shell customizations with: source ~/.bashrc'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
