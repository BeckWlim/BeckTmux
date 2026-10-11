#!/usr/bin/env bash

# Fixture-only migration tests, plus real Starship rendering when available.
set -Eeuo pipefail
PROMPT_TEST_PROJECT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT_TEST_DIR=$(mktemp -d /tmp/beck-prompt-tests.XXXXXXXX)
trap 'rm -rf -- "${PROMPT_TEST_DIR}"' EXIT

(
  source "${PROMPT_TEST_PROJECT}/scripts/setup-prompt.sh"
  PROMPT_CONFIG_DIR="${PROMPT_TEST_DIR}/config/tmux/shell"
  PROMPT_BASHRC="${PROMPT_TEST_DIR}/bashrc"
  cat >"${PROMPT_BASHRC}" <<'EOF'
alias keep_me=true
PROMPT_COMMAND='keep_hook'
if [[ -r "$HOME/.config/synth-shell/synth-shell-prompt.sh" ]]; then
  source "$HOME/.config/synth-shell/synth-shell-prompt.sh"
fi
source "$HOME/.config/synth-shell/alias.sh"
# >>> beck tmux Bash completion >>>
source "$HOME/.config/tmux/shell/completion.bash"
EOF
  cp "${PROMPT_BASHRC}" "${PROMPT_TEST_DIR}/original"
  configure_prompt
  bash -n "${PROMPT_BASHRC}"
  cp "${PROMPT_BASHRC}" "${PROMPT_TEST_DIR}/first"
  configure_prompt
  cmp "${PROMPT_BASHRC}" "${PROMPT_TEST_DIR}/first"
  python3 - "${PROMPT_BASHRC}" "${PROMPT_TEST_DIR}/original" <<'PY'
import pathlib
import sys

rc = pathlib.Path(sys.argv[1])
text = rc.read_text()
assert text.index('# >>> beck tmux Bash prompt >>>') < text.index('# >>> beck tmux Bash completion >>>')
assert 'alias keep_me=true' in text
assert "PROMPT_COMMAND='keep_hook'" in text
assert '\nsource "$HOME/.config/synth-shell/alias.sh"\n' in text
assert '\n  source "$HOME/.config/synth-shell/synth-shell-prompt.sh"' not in text
backups = list(rc.parent.glob(rc.name + '.bak.*'))
assert len(backups) == 1
assert backups[0].read_bytes() == pathlib.Path(sys.argv[2]).read_bytes()
PY
  cmp "${PROMPT_CONFIG_DIR}/starship.toml" "${PROMPT_TEST_PROJECT}/shell/starship.toml"
  printf '[prompt-test] ok: migration preserves aliases/hooks/completion, backs up once, and is idempotent\n'
)

bash -c 'PS1=unchanged; source "$1"; [[ $PS1 == unchanged ]]' test \
  "${PROMPT_TEST_PROJECT}/shell/prompt.bash"
printf '[prompt-test] ok: noninteractive shells keep their prompt\n'

if ! command -v starship >/dev/null; then
  printf '[prompt-test] SKIP: rendering tests require Starship on PATH\n'
  exit 0
fi
python3 - "${PROMPT_TEST_PROJECT}" "${PROMPT_TEST_DIR}" <<'PY'
import os
import pathlib
import re
import subprocess
import sys

project, temporary = map(pathlib.Path, sys.argv[1:])
env = os.environ | {'STARSHIP_CONFIG': str(project / 'shell/starship.toml'),
                    'STARSHIP_CACHE': str(temporary / 'cache'), 'TERM': 'xterm-256color'}

def render(directory, status=0, extra_env=None):
    result = subprocess.run(['starship', 'prompt', '--status', str(status)], cwd=directory,
                            env=env | (extra_env or {}), text=True, capture_output=True, check=True)
    assert not result.stderr, result.stderr
    # Context styling must end before the command input row.
    assert '\x1b[0m\n' in result.stdout, result.stdout
    # Every context block must preserve the terminal background. Check SGR
    # attributes without mistaking RGB components for background attributes.
    for code in re.findall(r'\x1b\[([0-9;]*)m', result.stdout):
        values = [int(value or 0) for value in code.split(';')]
        index = 0
        while index < len(values):
            value = values[index]
            assert value not in (7, 48) and not 40 <= value <= 47 and not 100 <= value <= 107, code
            if value == 38:
                index += 5 if values[index + 1] == 2 else 3
            else:
                index += 1
    return re.sub(r'\x1b\[[0-9;]*m', '', result.stdout), result.stdout

plain, success = render(temporary)
assert ' ' in plain and plain.count(' | ') == 1 and plain.endswith('\n$ '), plain
assert not plain[0].isspace() and plain.count('\n') == 1, plain
assert plain.startswith(os.environ.get('USER', '')) and '◈' not in plain, plain
assert '' not in plain and '' not in plain, plain
assert '\x1b[38;2;143;159;169m' in success, success
assert '\x1b[38;2;166;166;156m |  ' in success, success
assert '\x1b[38;2;230;230;222m$' in success, success
assert success.endswith('\x1b[0m '), success  # Command text starts after a style reset.
_, failure = render(temporary, 1)
assert '\x1b[38;2;249;38;114m$' in failure, failure

repo = temporary / 'repo'
repo.mkdir()
def git(*args):
    return subprocess.run(['git', '-C', str(repo), *args], text=True, capture_output=True, check=True)
git('init', '-b', 'prompt-test')
git('-c', 'user.name=Prompt Test', '-c', 'user.email=prompt@example.invalid',
    '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'fixture')
clean, clean_style = render(repo)
assert ' |  prompt-test\n$ ' in clean, clean
assert '\x1b[38;2;159;169;143m prompt-test\x1b[0m' in clean_style, clean_style
(repo / 'new.txt').write_text('new\n')
dirty, dirty_style = render(repo)
assert 'prompt-test ?\n$ ' in dirty, dirty
assert ' prompt-test ?\x1b[0m' in dirty_style, dirty_style
git('add', 'new.txt')
staged, _ = render(repo)
assert 'prompt-test +\n$ ' in staged, staged
git('checkout', '--detach')
detached, _ = render(repo)
assert detached.count('') == 1 and 'prompt-test' not in detached, detached
environment, environment_style = render(temporary, extra_env={'VIRTUAL_ENV': str(temporary / 'prompt-env')})
assert ' | venv:prompt-env\n$ ' in environment, environment
assert '\x1b[38;2;177;160;140mvenv:prompt-env\x1b[0m' in environment_style, environment_style
print('[prompt-test] ok: compact spacing, left alignment, subtle text colours, terminal background, command style reset, Git states, environment, and failure colour')
PY
