---
name: tmux-development
description: Develop or review this Beck tmux configuration and its setup or migration scripts. Use for changes to tmux.conf, scripts/*.sh, key bindings, status rendering, clipboard behavior, compatibility, installation, or migration; use tmux-testing alone for test-only requests.
---

# Beck tmux development

Preserve the repository's self-contained tmux design and validate changes without disturbing the
user's running server.

## Understand ownership and compatibility

- `tmux.conf` owns terminal capabilities, UI state, key tables, and version-gated tmux syntax.
- `scripts/setup.sh` owns workstation provisioning and must stay idempotent and preserve existing
  user configuration unless overwrite was explicitly requested.
- `scripts/migrate-tmux.sh` owns version download, build, validation, installation, backup, and
  server cutover. Keep build/check work separate from installation and destructive switching.
- `tests/run.sh` is the local, non-mutating validation entry point.

Read the relevant README section and inspect the current worktree before editing. Preserve unrelated
changes. When behavior differs by tmux version, retain an explicit `%if` boundary and test the
available compatible versions rather than assuming the newest parser.

## Preserve interaction invariants

- `C-a` is the sole prefix; `C-q`, `C-Space`, and application-owned `Escape` behavior remain
  available to terminal applications.
- A bare `Escape` enters copy mode only for ordinary shells. Full-screen applications receive it.
- Copy mode remains vi-like: `v` selects, copy keys keep command mode, and `i`/`q` return to input.
- Focus and mode indicators must describe tmux state without introducing plugin dependencies.
- Keep the configuration usable without TPM or oh-my-tmux.

## Treat operational scripts as external boundaries

Use `--help` and syntax checks during routine validation. Do not run `setup.sh` provisioning or the
migration script's `install` or `switch` actions unless the user explicitly requests their effects.
The migration `check` action downloads and builds tmux; use it only when cross-version validation is
material and network/build work is authorized.

Keep shell bindings stable: do not reuse parameters or locals for parsed paths, versions, command
output, or other semantic phases. Use narrowly named locals and quote filesystem paths.

## Verify changes

Run from the repository root:

```sh
./tests/run.sh
git diff --check
```

Run `shellcheck` over changed shell scripts when it is available. Add or update focused assertions
for changed behavior. Update `README.md` when a user-facing key, workflow, requirement, or command
changes. Report any compatibility version or external action that was not exercised.
