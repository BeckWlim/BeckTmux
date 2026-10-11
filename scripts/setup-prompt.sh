#!/usr/bin/env bash

# Configure the Beck prompt without provisioning packages or changing aliases.
set -Eeuo pipefail
PROMPT_PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/tmux/shell"
PROMPT_BASHRC="${HOME}/.bashrc"

usage() {
  cat <<'EOF'
Usage: setup-prompt.sh

Configure an installed Starship with the Beck foreground-only Bash prompt.
Back up ~/.bashrc, disable Synth Shell's prompt loader, and initialize Starship
before enhanced Bash completion. Existing aliases and completion are preserved.
Requires starship on PATH, Python 3, and a Nerd Font for directory/Git icons.
EOF
}

configure_prompt() {
  local prompt_file prompt_target
  mkdir -p "${PROMPT_CONFIG_DIR}"
  for prompt_file in prompt.bash starship.toml; do
    prompt_target="${PROMPT_CONFIG_DIR}/${prompt_file}"
    if [[ ! -e ${prompt_target} || ! ${PROMPT_PROJECT_DIR}/shell/${prompt_file} -ef ${prompt_target} ]]; then
      if [[ -e ${prompt_target} ]] && ! cmp -s "${PROMPT_PROJECT_DIR}/shell/${prompt_file}" "${prompt_target}"; then
        local prompt_backup
        prompt_backup=$(mktemp "${prompt_target}.bak.XXXXXXXX")
        cp -p "${prompt_target}" "${prompt_backup}"
      fi
      cp -p "${PROMPT_PROJECT_DIR}/shell/${prompt_file}" "${prompt_target}"
    fi
  done

  python3 - "${PROMPT_BASHRC}" <<'PY'
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

bashrc = pathlib.Path(sys.argv[1])
original = bashrc.read_text() if bashrc.exists() else ''
text = original
marker = '# >>> beck tmux Bash prompt >>>'
if marker not in text:
    # Only disable source commands for the old prompt, keeping its other tools.
    text = re.sub(
        r'''(?m)^([ \t]*)(?:source|\.)[ \t]+["']?[^\n"']*/synth-shell-prompt\.sh["']?[ \t]*$''',
        lambda match: match.group(1) + ': # Disabled by Beck Starship setup: ' + match.group(0).lstrip(),
        text,
    )
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

main() {
  case "${1-}" in
    -h|--help) usage; return ;;
    '') ;;
    *) usage >&2; return 2 ;;
  esac
  [[ $# == 0 ]] || { usage >&2; return 2; }
  command -v starship >/dev/null 2>&1 || {
    printf '[prompt-setup] Install Starship first: https://starship.rs/guide/\n' >&2
    return 1
  }
  command -v python3 >/dev/null
  configure_prompt
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
