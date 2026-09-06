# Beck tmux

This directory contains the terminal layer for the Beck workspace. Neovim owns
editor rendering; tmux owns panes, terminal history, and the bottom context bar.
The palette follows the local Monokai/Neovim values: `#272822` base,
`#3a3d3f` CursorLine/selection, `#a6e22e` focus, `#66d9ef` context, and
`#f8f8f2` primary text.

## Files

- `tmux.conf` — self-contained tmux configuration; no oh-my-tmux or TPM required.
- `setup.sh` — idempotently installs/checks tmux, eza, and synth-shell, then adds
  guarded eza aliases when they are missing.
- `README.md` — this usage and integration guide.

Tmux loads this file automatically from `~/.config/tmux/tmux.conf`.

## Mode context

The left side of the status bar always shows the active terminal context:

- `[ INPUT ]` — keys are delivered to the shell/application.
- `[ COMMAND ]` — tmux scrollback navigation is active.
- `[ VISUAL ]` — a scrollback selection is active.

While the `C-a` prefix is held, the right status cluster shows a final `│ ⟐`
segment as a small abstract command-layer cue rather than a keyboard glyph.

Each pane has a small top border tag such as `◈ P1 bash` or `○ P2 nvim`.
`◈` identifies the focused pane and its `◈ P#` label is green; `○` marks the
others. Pane borders stay neutral so the tag is the only focus accent. Window
and pane numbering both start at 1.

On a normal shell pane, press `Esc` to enter `COMMAND`. Use arrow keys or
`h/j/k/l` to move the free history cursor. Press `v` to enter `VISUAL`, `y` to
copy, and `i` to return to `INPUT`. The selected text uses the same subdued
`#3a3d3f` background as Neovim's `CursorLine`.

Neovim and other full-screen programs retain their own `Esc` behavior. The
tmux `Esc` binding only captures known shell processes (`bash`, `zsh`, `fish`,
`sh`, and `dash`). Codex (and any other non-shell process) receives the raw
`Esc`, so Codex can use it for its own visual/context inspection instead of
being forced into tmux copy mode.
To inspect Codex output in tmux, use `C-a j` and then `v`; this explicit
prefix path remains available without consuming Codex's `Esc` key.

Tmux also exports `COLORTERM=truecolor` and advertises the RGB terminal
feature. This keeps Neovim's GUI-only highlight groups (including the green
dashboard sections) intact inside tmux. After changing this setting, reload
the config and create a fresh pane; already-running processes keep their
original environment.

## Key bindings

The only tmux prefix is `C-a`; `C-q` and `C-Space` are deliberately left
available to terminal applications, Neovim, and input methods. Press `C-a`,
then:

| Key | Action |
| --- | --- |
| `R` | Reload `tmux.conf` |
| `a` | Cycle focus through split panes |
| `d` | Detach |
| `?` | List bindings |
| `c` | New window in the current directory |
| `n` / `p` | Next / previous window |
| `o` | Last window |
| `w` | Window chooser |
| `h` / `v` | Side-by-side / top-and-bottom split, preserving directory |
| `H` / `J` / `K` / `L` | Repeatable pane resize |
| `r` then `j` / `i` / `k` / `l` | Resize left / up / down / right |
| `=` / `+` | Even-horizontal / even-vertical layout |
| `j` | Enter copy mode manually |
| `]` | Paste the latest buffer |

Inside copy mode, `v` starts selection, `y` copies and exits, `i` exits without
copying, `q`/`C-q` exits, and arrows or `h/j/k/l` move the cursor.

## Supported prompts and commands

All tmux prompts use the same mode rendering: `#3a3d3f` while entering text,
then `#272822` with green text after `Esc` switches to command mode. Prompts
retain their original command key (`:`, `/`, `?`, `f`, `t`, `F`, or `T`) instead
of adding descriptive labels such as `(goto line)`.

- `C-a :` — enter a general tmux command.
- `C-a f` — search for a window.
- `C-a ,` — rename the current window.
- `C-a .` — move the current window.
- Copy mode `:` — go to a line number.
- Copy mode `/` / `?` — search forward / backward.
- Copy mode `f` / `t` / `F` / `T` — jump forward, to-forward, backward, or to-backward.

Inside any vi-style prompt, `Esc` enters command/navigation mode, arrow keys or
`h/j/k/l` move the cursor, and `i` returns to text input. `Enter` executes the
prompt; `q` cancels it.

## Shell integration

`eza` and synth-shell are already installed on this host and are initialized by
`~/.bashrc`. The existing aliases provide `ls`, `l`, `ll`, `la`, and `lt`; tmux
does not redefine them, so the same shell experience is preserved inside and
outside tmux. If those tools are unavailable on another machine, the shell
configuration falls back without affecting tmux startup.

Run `./setup.sh` when provisioning another machine. It skips tools and aliases
that already exist, installs eza through apt/dnf/pacman/Homebrew when possible,
and downloads synth-shell for its interactive installer when no user install is
present. It does not overwrite an existing shell or tmux configuration by
default. To intentionally replace a destination tmux config, use:

```sh
./setup.sh --overwrite
```

The previous tmux config is saved as `tmux.conf.bak.YYYYMMDD-HHMMSS` first.

## Validation and reload

Check the configuration without attaching to a live session:

```sh
TMUX_TMPDIR=/tmp/tmux-test tmux -L beck-check \
  -f ~/.config/tmux/tmux.conf new-session -d -s check
TMUX_TMPDIR=/tmp/tmux-test tmux -L beck-check kill-server
```

Reload an attached server with `C-a R`.

If Neovim was already running when the true-colour setting changed, start a
fresh pane (or restart the tmux server) so it inherits `COLORTERM=truecolor`.
