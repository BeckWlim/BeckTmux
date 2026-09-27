#!/usr/bin/env bash
set -euo pipefail
readonly paste_project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly paste_test_directory="$(mktemp -d /tmp/beck-paste-test.XXXXXXXX)"
trap 'rm -rf -- "$paste_test_directory"' EXIT
export BECK_PASTE_TEST_DIR="$paste_test_directory"
export PATH="$paste_test_directory:$PATH"
export WAYLAND_DISPLAY=clipboard-test
cat > "$paste_test_directory/wl-paste" <<'STUB'
#!/bin/bash
[[ "$1" == --no-newline ]] || exit 2
[[ ! -f "$BECK_PASTE_TEST_DIR/fail" ]] || exit 1
cat "$BECK_PASTE_TEST_DIR/input"
STUB
cat > "$paste_test_directory/tmux" <<'STUB'
#!/bin/bash
[[ "$1" == -S && "$2" == test-socket ]] || exit 2
shift 2
case "$1" in
  display-message)
    if [[ "$2" == -p ]]; then cat "$BECK_PASTE_TEST_DIR/command"; fi ;;
  load-buffer)
    cp "${@: -1}" "$BECK_PASTE_TEST_DIR/loaded" ;;
  paste-buffer)
    printf '%s\n' "$@" > "$BECK_PASTE_TEST_DIR/arguments" ;;
  delete-buffer) ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$paste_test_directory/wl-paste" "$paste_test_directory/tmux"
printf 'bash\n' > "$paste_test_directory/command"
printf '中文 café\nsecond line\n\n' > "$paste_test_directory/input"
"$paste_project/scripts/paste-clipboard.sh" test-socket %7
cmp "$paste_test_directory/input" "$paste_test_directory/loaded"
grep -qx -- '-p' "$paste_test_directory/arguments"
grep -qx -- '-r' "$paste_test_directory/arguments"
grep -qx -- '%7' "$paste_test_directory/arguments"
rm "$paste_test_directory/loaded" "$paste_test_directory/arguments"
touch "$paste_test_directory/fail"
if "$paste_project/scripts/paste-clipboard.sh" test-socket %7; then
  printf 'FAIL: clipboard read failure was ignored\n' >&2
  exit 1
fi
[[ ! -e "$paste_test_directory/loaded" && ! -e "$paste_test_directory/arguments" ]]
rm "$paste_test_directory/fail"
printf 'nvim\n' > "$paste_test_directory/command"
"$paste_project/scripts/paste-clipboard.sh" test-socket %7
[[ ! -e "$paste_test_directory/loaded" && ! -e "$paste_test_directory/arguments" ]]
printf '[test] clipboard bytes, bracketed-paste flags, target pane, failure and application handoff passed\n'
