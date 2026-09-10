---
name: tmux-testing
description: Test, diagnose, or extend validation for this Beck tmux repository. Use for test requests, regressions, tmux.conf parsing, key-table assertions, shell-script checks, or compatibility verification; do not use it to provision tools, install tmux, or switch a live server.
---

# Beck tmux testing

Exercise observable configuration behavior through a disposable tmux server and keep all live tmux
sessions untouched.

## Use the project test entry point

Run from the repository root:

```sh
./tests/run.sh
git diff --check
```

The suite syntax-checks executable shell scripts, exercises their help paths, loads `tmux.conf` on an
isolated socket, and inspects effective options and key tables. Treat a missing `bash` or `tmux` as a
reported environment prerequisite, not a reason to rewrite or skip the assertions silently.

## Extend tests with behavior

When production behavior changes, add the narrowest assertion that observes the effective tmux
option, hook, format, environment value, or binding. Prefer querying the disposable server over
matching source text. Keep version-specific expectations conditional on the actual `tmux -V`
result, and ensure cleanup runs after both success and failure.

Use a unique socket beneath a `mktemp` directory. Always pass that socket explicitly with `tmux -S`;
never issue `source-file`, `kill-server`, `kill-session`, or configuration mutations against the
default/live server. Keep temporary-path variables distinct from socket paths and command output.

The migration script's `check` action is an optional, slower compatibility gate because it downloads
and compiles a requested tmux release. Run it only when version compatibility is in scope and its
network/build work is authorized. Never use `install` or `switch` as a test.

If `shellcheck` is installed, run it on changed shell scripts. Otherwise report that this static lint
coverage was unavailable; do not replace it with suppressed warnings or looser shell behavior.
