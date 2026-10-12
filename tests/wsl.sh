#!/usr/bin/env bash
set -Eeuo pipefail
readonly WSL_TEST_PROJECT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WSL_TEST_DIR="$(mktemp -d /tmp/beck-wsl-tests.XXXXXXXX)"
trap 'rm -rf -- "${WSL_TEST_DIR}"' EXIT

bash -c 'before=$PATH; source "$1"; [[ $PATH == "$before" ]]; ! declare -F win' \
  test "${WSL_TEST_PROJECT}/shell/wsl.bash"

cat >"${WSL_TEST_DIR}/windows-tool" <<'EOF'
#!/bin/bash
printf '%s\n' "$@"
exit 7
EOF
chmod +x "${WSL_TEST_DIR}/windows-tool"

# Emulate the kernel identifier so this fixture also works on ordinary Linux.
# The loader must not invoke external commands to classify or filter PATH.
bash --noprofile --norc -ic '
  read() { printf -v _beck_wsl_release "%s" "test-microsoft-WSL2"; }
  PATH="/usr/bin:/bin::/mnt/c/Windows/System32:/mnt/d/Program Files/Tools:/usr/local/bin:"
  unset BECK_WSL_WINDOWS_PATH
  source "$1"
  expected_path="/usr/bin:/bin::/usr/local/bin:"
  expected_windows="/mnt/c/Windows/System32:/mnt/d/Program Files/Tools"
  [[ $PATH == "$expected_path" && $BECK_WSL_WINDOWS_PATH == "$expected_windows" ]] || exit 1
  source "$1"
  [[ $PATH == "$expected_path" && $BECK_WSL_WINDOWS_PATH == "$expected_windows" ]] || exit 2
  bash --noprofile --norc -c '\''[[ $BECK_WSL_WINDOWS_PATH == "$1" ]]'\'' test "$expected_windows" || exit 3
  BECK_WSL_WINDOWS_PATH="$2"
  win windows-tool "two words" "literal *" >"$2/result"
  [[ $? == 7 && $PATH == "$expected_path" ]] || exit 4
  [[ $(<"$2/result") == $'\''two words\nliteral *'\'' ]] || exit 5
  win >/dev/null 2>&1
  [[ $? == 2 ]] || exit 6
  read() { printf -v _beck_wsl_release "%s" "test-linux"; }
  PATH="/usr/bin:/mnt/c/Windows/System32"
  source "$1"
  [[ $PATH == "/usr/bin:/mnt/c/Windows/System32" ]] || exit 7
' test "${WSL_TEST_PROJECT}/shell/wsl.bash" "${WSL_TEST_DIR}"
printf '[wsl-test] ok: filtering, empty entries, reloads, inheritance, win arguments/status, and non-WSL guard\n'
