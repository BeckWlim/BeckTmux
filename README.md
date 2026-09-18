# Beck tmux

This directory contains the terminal layer for the Beck workspace. Neovim owns
editor rendering; tmux owns panes, terminal history, and the bottom context bar.
The default night palette uses Monokai values: `#272822` base,
`#3a3d3f` CursorLine/selection, `#a6e22e` focus, `#66d9ef` context, and
`#f8f8f2` primary text.

## Files

- `tmux.conf` — self-contained tmux configuration; no oh-my-tmux or TPM required.
- `scripts/setup.sh` — idempotently installs/checks tmux, eza, and synth-shell, then adds
  guarded eza aliases when they are missing.
- `scripts/migrate-tmux.sh` — safely builds, validates, installs, and switches to a
  requested tmux release while preserving the currently installed binary.
- `scripts/theme.sh` — opt-in application hook to set or reset a pane's palette.
- `tests/run.sh` — smoke-tests shell entry points and the effective configuration on
  an isolated tmux server.
- `README.md` — this usage and integration guide.

Tmux loads this file automatically from `~/.config/tmux/tmux.conf`.

## Application theme hook

Tmux owns its default night palette. Applications can explicitly publish colours
for their own pane through `scripts/theme.sh` (Bash 4 or newer, and `ps` with
`tty`, `pgid`, `tpgid`, `stat`, `lstart`, and `comm` fields):

```sh
# Invoked by the foreground application.
~/.config/tmux/scripts/theme.sh set \
  'bg=#fafaf7' 'fg=#242424' 'cursor=#e5e5e0' \
  'border=#777770' 'muted=#666660' 'green=#3d6815' 'cyan=#006b80'

# The same application releases its palette.
~/.config/tmux/scripts/theme.sh reset

# Manual recovery from the shell, regardless of the publisher.
~/.config/tmux/scripts/theme.sh reset --force
```

Colours must be `#RRGGBB`. Each `set` replaces the pane's previous palette.
Applications publish this standard set of roles through the hook:

| Role | Purpose / fallback when omitted |
| --- | --- |
| `bg`, `fg` | Base background and primary text; default night colours |
| `cursor` | Selection and selected-window background; default night colour |
| `muted`, `border` | Secondary text and neutral borders; default night colours |
| `green`, `cyan` | Focus accent and contextual information; default night colours |
| `surface`, `yellow`, `purple`, `red` | Reserved surface and semantic accents |
| `window_active_fg` | Selected window label; the application's `green` |
| `window_active_bg` | Selected window background; the application's `cursor` |
| `window_inactive_fg` | Unselected window label; the application's `muted` |
| `window_inactive_bg` | Unselected window background; the application's `bg` |

The existing Neovim palette roles remain supported. The four `window_*` roles
are optional; their fallbacks derive from the same application's base palette.
For consistent light themes, applications should publish all base roles used by
the UI rather than leave individual colours at their night defaults.

Tmux keeps separate colour namespaces:

| Namespace | Owner and scope |
| --- | --- |
| `@beck_default_*` | Tmux's global night defaults |
| `@beck_palette_*` | Application palette cached on its pane by `theme.sh` |
| `@beck_pane_*` | Tmux formats resolving that pane's colours and fallbacks |
| `@beck_ui_*` | Tmux formats resolving the session's focused palette for shared UI |

Use the hook to publish colours so ownership and automatic recovery stay active.
For inspection, `tmux display -p '#{E:@beck_ui_bg}'` shows the shared UI background;
`#{E:@beck_pane_bg}` shows the target pane's own background.

The hook uses the application's inherited `TMUX` and `TMUX_PANE` to target its
server and pane. It never changes the global default palette. Each window retains
its applications' palettes in tmux's pane options. Switching windows or panes
selects the stored palette during tmux's normal redraw: no application callback,
external command, or watchdog tick is needed to switch colours. Updates from an
unfocused application refresh its own stored palette for the next switch.

The status bar, selected and unselected window tags, pane borders, and prompts
all use the focused pane's UI palette. Inactive window tags explicitly set both
foreground and background, without inheriting reverse or bold highlighting.
Terminal contents and copy selections retain their own pane's colours. Returning
to an ordinary shell pane shows the default night palette. Tmux has no Neovim
dependency and does not read application theme files.

Applications should call `set` on startup, colour changes, and resume, and `reset`
before exit or suspend. Each publication also starts a tmux-owned watcher that
checks the publisher's process identity and foreground terminal ownership once a
second. Exiting, crashing, killing the application job, or suspending back to the
shell restores the default palette on the next check without application cleanup.
Changing focus to another pane does not revoke a running application's palette.
Losing terminal-window focus also preserves the palette. On Linux, owner identity
uses the kernel's process-start ticks, so wall-clock changes cannot revoke a live
application's palette. Other platforms use `ps` start times in UTC.
No heartbeat is required from the application.

The publisher defaults to the hook's parent process. Applications invoking the
hook through a shell wrapper must pass their own PID explicitly, for example
`theme.sh set --owner 12345 'bg=#282c34'`. The owner must be running in this pane's
foreground process group. `reset --owner 12345` releases that publisher's palette;
an old publisher cannot reset a newer owner's colours. Each publication has a
generation token, so an old watcher cannot clear a newer publication either.
Config reloads preserve valid overrides, and watchers stop after reset, ownership
replacement, pane removal, or server shutdown. Recovery has been tested on Linux;
other platforms need compatible `ps` output.
After updating the watcher, republish the application palette once (for example,
reapply the Neovim colorscheme) to replace any watcher already running.

After updating from the earlier hook, reload tmux with `C-a R` and let applications
republish once (for example by reapplying the Neovim colorscheme). Old pane overrides
are removed on the next `set` or `reset`; subsequent switches use the stored palette.

For the local BeckNvim configuration, this optional Lua snippet uses its existing
`config.ui.palette.resolve()` boundary. Add it to Neovim startup to opt in; the
tmux configuration does not install or enable it automatically:

```lua
if vim.env.TMUX and vim.env.TMUX_PANE then
  local hook_path = vim.fn.expand('~/.config/tmux/scripts/theme.sh')
  local owner_pid = tostring(vim.fn.getpid())
  local application_active = true
  local group = vim.api.nvim_create_augroup('beck_tmux_theme', { clear = true })

  local function call_hook(arguments)
    local command = { hook_path }
    vim.list_extend(command, arguments)
    -- Serialize updates so an earlier palette cannot arrive after reset.
    local result = vim.system(command, { text = true }):wait(1000)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify('tmux theme: ' .. (result.stderr or 'hook failed'), vim.log.levels.WARN)
      end)
    end
  end

  local function publish()
    if not application_active then return end
    local colors = require('config.ui.palette').resolve()
    local roles = {
      bg = colors.background, fg = colors.foreground,
      cursor = colors.selection, border = colors.border, muted = colors.muted,
      green = colors.syntax.func, cyan = colors.syntax.type,
    }
    local arguments = { 'set', '--owner', owner_pid }
    for role, color in pairs(roles) do
      arguments[#arguments + 1] = string.format('%s=#%06x', role, color)
    end
    call_hook(arguments)
  end

  vim.api.nvim_create_autocmd({ 'VimEnter', 'ColorScheme', 'VimResume', 'ShellCmdPost' }, {
    group = group,
    callback = function()
      application_active = true
      -- Read colours after the colorscheme's highlight callbacks finish.
      vim.schedule(publish)
    end,
  })
  vim.api.nvim_create_autocmd({ 'VimLeavePre', 'VimSuspend' }, {
    group = group,
    callback = function()
      application_active = false
      call_hook({ 'reset', '--owner', owner_pid })
    end,
  })
  vim.schedule(publish)
end
```

The example needs Neovim 0.10+ and the local hook script. Other applications can
call the same `set`/`reset` interface with their own palette.

## Mode context

The left side of the status bar always shows the active terminal context:

- `[ INPUT ]` — keys are delivered to the shell/application.
- `[ COMMAND ]` — tmux scrollback navigation is active.
- `[ VISUAL ]` — a scrollback selection is active.

While the `C-a` prefix is held, the right status cluster shows a final `│ ⟐`
segment as a small abstract command-layer cue rather than a keyboard glyph.

The right side begins with `[ FOCUSED ]` in green while the terminal window
displaying the tmux client has focus. The tag disappears when it does not. This
uses terminal focus events, so it tracks focus moving between terminal windows
as well as between applications. Focus hooks target and refresh the affected
client immediately; a one-second periodic update covers missed terminal events.

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
| `Up` / `Down` / `Left` / `Right` | Focus the adjacent pane (one-shot) |
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

Inside copy mode, `v` starts selection. Mouse drag selections stay active after
release. `y`/`C-c` copy and clear the selection while preserving command mode and
the cursor position. `Enter` does the same when a selection exists and otherwise
keeps command mode active. `i`, `q`, or `C-q` returns to input mode.

On tmux 3.6 or newer, when WSL's `clip.exe` bridge is available, those copy keys
use it asynchronously and suppress OSC 52 for that operation. This avoids a
terminal clipboard stall while still updating tmux's paste buffer and the
Windows clipboard. Other terminal environments continue to use tmux's native
OSC 52 integration.

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

On tmux 3.7 or newer, the `:` and `/` prompts place input directly after the
prompt character and Backspace closes the prompt when it is empty.

Inside any vi-style prompt, `Esc` enters command/navigation mode, arrow keys or
`h/j/k/l` move the cursor, and `i` returns to text input. `Enter` executes the
prompt; `q` cancels it.

## Shell integration

`eza` and synth-shell are already installed on this host and are initialized by
`~/.bashrc`. The existing aliases provide `ls`, `l`, `ll`, `la`, and `lt`; tmux
does not redefine them, so the same shell experience is preserved inside and
outside tmux. If those tools are unavailable on another machine, the shell
configuration falls back without affecting tmux startup.

Run `./scripts/setup.sh` when provisioning another machine. It skips tools and aliases
that already exist, installs eza through apt/dnf/pacman/Homebrew when possible,
and downloads synth-shell for its interactive installer when no user install is
present. It does not overwrite an existing shell or tmux configuration by
default. Optional steps run independently: a package, download, or installer
failure emits a warning and allows the other steps to continue. Setup returns
success after optional failures and summarizes them at the end; configuration
installation errors still stop setup. Eza aliases are added only if eza is
available. To install synth-shell without attempting eza:

```sh
./scripts/setup.sh --skip-eza
source ~/.bashrc
```

Use `--skip-synth-shell` to skip synth-shell instead. Its installer runs
interactively; without a terminal, setup downloads it and prints the installer
path for later activation. To intentionally replace a destination tmux config, use:

```sh
./scripts/setup.sh --overwrite
```

The previous tmux config is saved as `tmux.conf.bak.YYYYMMDD-HHMMSS` first.

## Tmux version migration

The generic migration script accepts the target release as its first argument.
Build and validate a release without changing the installed binary or running
server:

```sh
./scripts/migrate-tmux.sh 3.6b check
```

Install the validated build under `/usr/local`. The currently installed binary
is preserved using its reported version, such as `/usr/local/bin/tmux-3.7c`.
The running server and its panes continue using their existing version until
explicitly switched:

```sh
./scripts/migrate-tmux.sh 3.6b install
```

The `check` action does not install the target. Complete `install` successfully
before running `switch`.

After saving work and leaving tmux normally, start the target server from an
outside shell:

```sh
./scripts/migrate-tmux.sh 3.6b switch
```

If a server is still running, `switch` refuses to stop it and lists its panes.
The destructive `switch --kill-old-server` form is available only for an
intentional forced cutover.

## Validation and reload

Run the complete non-mutating smoke suite:

```sh
./tests/run.sh
```

Check the configuration without attaching to a live session:

```sh
TMUX_TMPDIR=/tmp/tmux-test tmux -L beck-check \
  -f ~/.config/tmux/tmux.conf new-session -d -s check
TMUX_TMPDIR=/tmp/tmux-test tmux -L beck-check kill-server
```

Reload an attached server with `C-a R`.

If Neovim was already running when the true-colour setting changed, start a
fresh pane (or restart the tmux server) so it inherits `COLORTERM=truecolor`.
