# Beck tmux

This directory contains the terminal layer for the Beck workspace. Tmux owns
panes, terminal history, clipboard routing, and the bottom context bar.
The default night palette uses Monokai values: `#272822` base,
`#3a3d3f` CursorLine/selection, `#a6e22e` focus, `#66d9ef` context, and
terminal-default primary text.

## Files

- `tmux.conf` — self-contained tmux configuration; no oh-my-tmux or TPM required.
- `scripts/setup.sh` — idempotently installs/checks tmux, eza, and synth-shell, then adds
  guarded eza aliases when they are missing.
- `scripts/setup-completion.sh` — optional ble.sh installation and Bash Tab setup.
- `shell/completion.bash` — Vim input editing, mode tag, history suggestions, and completion menus.
- `scripts/setup-prompt.sh` — backs up Bash configuration and switches its prompt to Starship.
- `shell/prompt.bash`, `shell/starship.toml` — prompt initialization and subtle context text colours.
- `scripts/migrate-tmux.sh` — safely builds, validates, installs, and switches to a
  requested tmux release while preserving the currently installed binary.
- `scripts/theme.sh` — opt-in application hook to set or reset a pane's palette.
- `scripts/clipboard.sh` — shared clipboard policy for local and SSH clients.
- `scripts/setup-clipboard.sh` — optional tmux-fzf installation and clipboard history setup.
- `scripts/clipboard-history.sh` — system history picker and lossless paste adapter.
- `scripts/windows-clipboard-history.ps1` — Windows clipboard history provider for WSL.
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

The four `window_*` roles are optional; their fallbacks derive from the same application's base palette.
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
to an ordinary shell pane shows the default night palette. Tmux does not read
application theme files.

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

Palette publication and cleanup also invalidate tmux's cached pane colours.
This lets the pane background return to the night default after leaving a light
application, without a config reload. If a pane
is already stuck, run `~/.config/tmux/scripts/theme.sh reset --force` in its shell.

The publisher defaults to the hook's parent process. Applications invoking the
hook through a shell wrapper must pass their own PID explicitly, for example
`theme.sh set --owner 12345 'bg=#282c34'`. The owner must be running in this pane's
foreground process group. `reset --owner 12345` releases that publisher's palette;
an old publisher cannot reset a newer owner's colours. Each publication has a
generation token, so an old watcher cannot clear a newer publication either.
Config reloads preserve valid overrides, and watchers stop after reset, ownership
replacement, pane removal, or server shutdown. Recovery has been tested on Linux;
other platforms need compatible `ps` output.
After updating the watcher, republish the application palette once to replace
any watcher already running.

After updating from the earlier hook, reload tmux with `C-s R` and let applications
republish once. Old pane overrides
are removed on the next `set` or `reset`; subsequent switches use the stored palette.

## Mode context

The left side of the status bar always shows the active terminal context:

- `[ INPUT ]` — keys are delivered to the shell/application.
- `[ COMMAND ]` — tmux scrollback navigation is active.
- `[ VISUAL ]` — a scrollback selection is active.

While the `C-s` prefix is held, the right status cluster shows a final `│ ⟐`
segment as a small abstract command-layer cue rather than a keyboard glyph.

The right side begins with `[ FOCUSED ]` in green while the terminal window
displaying the tmux client has focus. The tag disappears when it does not. This
uses terminal focus events, so it tracks focus moving between terminal windows
as well as between applications. Focus hooks target and refresh the affected
client immediately; a one-second periodic update covers missed terminal events.

Each pane has a small top border tag such as `◈ P1 bash` or `○ P2 less`.
`◈` identifies the focused pane and its `◈ P#` label is green; `○` marks the
others. Pane borders stay neutral so the tag is the only focus accent. Window
and pane numbering both start at 1.

Press `C-s j` to enter tmux `COMMAND` mode. Use arrow keys or
`h/j/k/l` to move the free history cursor. Press `v` to enter `VISUAL`, `y` to
copy, and `i` to return to `INPUT`. Selected text uses a subdued `#3a3d3f`
background.

In `INPUT` mode, `Ctrl+h/j/k/l` sends Left/Down/Up/Right to the foreground
application without a prefix. `Ctrl+d` retains the foreground application's native behavior.
These replace the application's native shortcuts
for those keys, including Ctrl+h backspace and Ctrl+l clear-screen. Up/Down
follow the application's behavior, such as shell history or multiline navigation.

Use your terminal’s native paste shortcut for the system clipboard.
`C-s ]` pastes tmux’s buffer. `Ctrl+p` passes through to the foreground application,
including previous-command history in shells that use that shortcut.

`Esc` passes through to the foreground shell or application. Bash can use it
for Vim editing of the current command, and full-screen programs retain their
own `Esc` behavior. To inspect terminal output in tmux, use `C-s j` and then `v`.

Tmux also exports `COLORTERM=truecolor` and advertises the RGB terminal
feature. This preserves applications' 24-bit colours inside tmux. After changing this setting, reload
the config and create a fresh pane; already-running processes keep their
original environment.

## Key bindings

When switching from the old prefix, press `C-b R` once to load this change.
Afterward, use `C-s R` to reload. Press `C-s C-s` to send a literal `Ctrl+S`
to an application (for example, its Save shortcut).

In scrollback command mode and visual mode, `Ctrl+A` moves to the beginning
of the line and `Ctrl+E` moves to the end, without the tmux prefix.

The only tmux prefix is `C-s`; `C-a`, `C-b`, `C-q`, and `C-Space` are deliberately left
available to terminal applications and input methods. Press `C-s`,
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
| `f` | Search system clipboard history and paste one text item |

Inside copy mode, `v` starts selection. Mouse drag selections stay active after
release. `y`/`C-c` copy and clear the selection while preserving command mode and
the cursor position. `Enter` does the same when a selection exists and otherwise
keeps command mode active. `i`, `q`, or `C-q` returns to input mode.

On tmux 3.6 or newer, local clients prefer `wl-copy --type text/plain` when
Wayland is available. In WSLg,
this also updates the Windows clipboard and preserves Unicode text directly.
Without Wayland, WSL's `clip.exe` bridge remains a fallback when `iconv` is
available; selections are converted from UTF-8 to UTF-16LE for Windows.
`scripts/clipboard.sh` chooses the route at keypress time for the calling client.
On Linux/WSL it reads that client's SSH environment, so an SSH client uses OSC 52
even when sharing a session started on the local desktop. Local clients keep
the native provider, which runs asynchronously and suppresses OSC 52 for that
operation. Tmux owns the paste buffer and OSC 52 delivery. With no native
provider, copying uses OSC 52 as well. Paste local clipboard text with your
terminal's Paste action, or use `C-s ]` for the latest tmux buffer.

### System clipboard history

Press **`C-s f`**, select an item with `j`/`k` or Up/Down, and press `o` or Enter
to paste into the pane that opened the picker. It opens in selection mode;
`/` enters search and Ctrl-G returns to selection. In search mode, type any text
(including `q` and `o`), press Enter to paste, or Ctrl-Q to quit. In selection mode,
`q` quits; Escape closes either mode without pasting. The list is on the left and the wrapped
preview on the right (55% of the popup width). Popup height follows the history
length, with up to 12 visible entries and scrolling for longer histories. This uses the
optional [tmux-fzf](https://github.com/sainnhe/tmux-fzf) plugin's clipboard entry,
with a maintained adapter that snapshots text history, preserves Unicode and
trailing newlines, and honours application bracketed paste. Clipboard changes
while the picker is open do not change the selected item's contents.

The popup, list and preview share tmux's existing `@beck_ui_*` palette roles:
`bg`/`fg` for normal text, `cursor` for the selected row, `green` for focus and
matching, `muted` for hints, `cyan` for counts, and `border` for the frame and
preview divider. These resolve the focused application's palette with the
`@beck_default_*` fallback. There is no separate clipboard colour palette.

Install through the existing setup entry point:

```sh
./scripts/setup.sh --clipboard
```

To install only this integration, use `./scripts/setup-clipboard.sh --install-deps`.
Both reuse existing tools. Pop!_OS, Ubuntu and Debian use their configured apt
repositories for `git`, `fzf` and (on Linux desktops) `copyq`; setup does not add
a repository, pin a distro release, or upgrade the OS. Missing optional packages
are reported without preventing the rest of `setup.sh` from completing.

On Linux, CopyQ records desktop clipboard changes. Setup adds a desktop autostart
entry if absent; start it for the current login with
`./scripts/clipboard-history.sh start`, then reload using `C-s R`.
CopyQ must be running when text is copied; past copies from before recording
started cannot be recovered. On GNOME/Pop!_OS 22.04, the distro's older CopyQ
works with the X11 session. Wayland capture depends on desktop protocols; older
CopyQ may require its XWayland workaround, while newer versions support additional
compositors. See [CopyQ's Wayland notes](https://copyq.readthedocs.io/en/latest/known-issues.html).
Pop!_OS 24.04/COSMIC monitoring needs verification on that desktop.

In WSL, the provider reads **Windows clipboard history** using Windows PowerShell
interop (`powershell.exe` and `wslpath`), rather than running a separate Linux
clipboard monitor. Enable **Settings → System → Clipboard → Clipboard history**
on Windows 10 1809 or newer / Windows 11. Text copied in Windows applications
then appears in the tmux picker. Windows line endings become LF; trailing
newlines remain intact. This requires the interactive Windows user's clipboard
session. The Windows provider is covered by fixtures here; it must also be
verified on an actual WSL desktop.

The plugin is installed at a pinned commit under ignored `plugins/tmux-fzf`.
Its clipboard entry delegates to the adapter in `scripts/`, so edits take effect
on the next open without reinstalling a second copy. History is retrieved once
per open for both popup sizing and selection. TPM is optional. For a machine without sudo, the separate
`--local-runtime` option extracts the distro's fzf/CopyQ packages under `plugins/`;
their shared libraries must already be installed. `--no-autostart` skips the
desktop startup entry. SSH clients receive a message instead of accessing the
remote server's desktop history.

## Supported prompts and commands

All tmux prompts use the same mode rendering: `#3a3d3f` while entering text,
then `#272822` with green text after `Esc` switches to command mode. Prompts
retain their original command key (`:`, `/`, `?`, `f`, `t`, `F`, or `T`) instead
of adding descriptive labels such as `(goto line)`.

- `C-s :` — enter a general tmux command.
- `C-s f` — search for a window.
- `C-s ,` — rename the current window.
- `C-s .` — move the current window.
- Copy mode `:` — go to a line number.
- Copy mode `/` / `?` — search forward / backward.
- Copy mode `f` / `t` / `F` / `T` — jump forward, to-forward, backward, or to-backward.

On tmux 3.7 or newer, the `:` and `/` prompts place input directly after the
prompt character and Backspace closes the prompt when it is empty.

Inside any vi-style prompt, `Esc` enters command/navigation mode, arrow keys or
`h/j/k/l` move the cursor, and `i` returns to text input. `Enter` executes the
prompt; `q` cancels it.

## Shell integration

### Vim editing at the Bash prompt

The optional ble.sh integration starts each command in shell Insert mode.
Press `Esc` or `Ctrl+O` to enter shell Normal mode and edit the current command
with Vim motions, operators, text objects, visual selection, and undo. Use `i`, `a`, or
`A` to resume typing. For example, `ci"` replaces the contents of a quoted
argument; `w`/`b` move between words and `u` undoes an edit. `Ctrl+C` abandons
the current command in either shell editing mode.
In Normal mode, `/pattern` searches forward within the current command and
`?pattern` searches backward; Enter confirms the search and Escape cancels it.
Search wraps at either end, with `n` repeating and `N` reversing the search.
Press Enter in Insert or Normal mode to submit the command, including multiline
input. Use `Alt+Enter` in Insert mode to add a newline without submitting.
In shell Visual mode, `i` clears the selection and resumes typing at the cursor
without replacing the selected text. This overrides Visual mode's usual `i` text-object
prefix; Normal-mode text objects such as `ci"` remain available.

Tmux stays in `[ INPUT ]` throughout shell editing and passes these keys to Bash.
Shell Normal mode does not navigate terminal output. `C-s j` enters
tmux's `[ COMMAND ]` mode to inspect scrollback and copy text; `i` or `q` leaves
scrollback and returns to the shell's existing editing state.

A muted `[INSERT]`, `[NORMAL]`, or `[VISUAL]` tag appears after the prompt's
context text and updates immediately as shell modes change. The tag follows
normal text wrapping when the window is resized. Replace
and select modes have their own tags. This is independent of tmux's mode label;
the command-input row stays clear for long commands.

Open a new Bash shell to load these settings, or source
`~/.config/tmux/shell/completion.bash` in an existing interactive shell.

### Enhanced Bash Tab completion

The optional completion setup uses [ble.sh](https://github.com/akinomyoga/ble.sh)
for inline suggestions from command history and Bash's programmable completions.
**Tab accepts the next word of a visible suggestion.** Without a suggestion,
Tab performs normal completion and opens the completion menu when appropriate.
For multiple matches, Tab shows the menu, subsequent Tab presses select and cycle
through its items, and Shift-Tab cycles backward. Enter confirms the selected
completion without executing the command; press Enter again to run it. Arrow
keys also navigate the menu, and typing filters it. Ambiguous syntax candidates
are left for the menu instead of suggesting an arbitrary first match inline.
The menu follows Neovim's completion styling: at most ten visible rows, normal
text on the editor background, a bold selection on the CursorLine background,
green matching text, and muted descriptions and inline suggestions. Inside tmux,
colours come from its `@beck_default_*` roles at shell startup; outside tmux they
use the same Monokai defaults. Bash draws its native menu beneath the prompt,
rather than reproducing Neovim's floating window.
Right Arrow at the end of the line accepts the whole suggestion; Ctrl-G dismisses
it, so the next Tab can show other candidates instead. Suggestions are inserted,
not executed; Enter still runs the command.

Install and enable it independently of eza and synth-shell:

```sh
./scripts/setup-completion.sh
```

Or include it in workstation provisioning with `./scripts/setup.sh --completion`.
The standalone script reuses an installed ble.sh, otherwise downloads the official
nightly release using curl, tar, and xz. It backs up `.bashrc` before appending a
guarded loader, preserves `.blerc`, and does not repeat the loader on subsequent
runs. Use `--no-install` to configure an existing installation without downloads.
Open a new Bash shell afterward. Bash 4 or newer is required.

This belongs to Bash rather than a global tmux Tab binding: the same completion
works inside and outside tmux, including repository-aware branch completion.
`shell/completion.bash` holds the shared settings. Tmux passes Tab through to the
foreground application. SSH shells need this setup on the remote host as well.

If [carapace-bin](https://carapace-sh.github.io/carapace-bin/setup.html) is on PATH,
the loader also registers its command-specific completions and descriptions.
Without it, existing Bash completions (including Git) remain available. Examples:

```text
git sw<Tab>                     # Complete the subcommand
git log --on<Tab>               # Complete a git-log option
git switch origin/v0.<Tab>      # Complete an existing remote branch
```

These sources describe valid command syntax; they do not scrape every program's
`-h` output on each keystroke. For a custom CLI without completion, tools such as
[crazy-complete](https://github.com/crazy-complete/crazy-complete) can generate
definitions from its help text for review. Prefer the existing Git completer to
generating one from Git's help.

To disable the optional integration, remove the marked `beck tmux Bash completion`
block from `.bashrc` and start a new shell.

### Existing shell customizations

This host uses Starship for its Bash prompt, with soft grey context text,
plain `|` separators, directory/Git icons, and subtle text-colour differences:

```text
ffxiao@beck-main |  ~/.config/tmux |  master *? [INSERT]
$
```

Prompts have no extra blank line above them. Context and command input align with command
output at the left edge, with input on its own line to leave room for long commands.
Prompt spacing uses whole terminal rows; half-line margins are not supported.

The `user@host` identity uses a deeper, low-saturation slate blue (`#8f9fa9`).
The directory, separators, and inline Vim-mode tag use soft grey (`#a6a69c`),
Git branch/status use muted green (`#9fa98f`), and Python environments use warm
grey (`#b1a08c`). These are text colours only: every section retains the terminal's
default background. The mode tag stays attached to the context row when the
terminal resizes.
The normal `$` uses a brighter warm grey (`#e6e6de`) to mark the input line.
Root, read-only paths, Git operations in progress, and failed commands retain pink
accents. Git indicators include `*` modified, `?` untracked,
`+` staged, `!` conflicts, `≡` stashes, and `↑N`/`↓N` ahead/behind. The final `$`
turns pink after a failed command. Detached HEAD shows the commit hash, and active
Python environments appear as `venv:name`. The GitHub-style icon labels the Git
section for all repositories. Prompt rendering does not fetch from remotes.
Icons require a Nerd Font; this host's Konsole profile uses FiraCode Nerd Font.

To reproduce this setup, install [Starship](https://starship.rs/guide/), then run:

```sh
./scripts/setup-prompt.sh
exec bash
```

Setup backs up `.bashrc`, disables only Synth Shell's prompt source command, and
loads `shell/prompt.bash` before the completion integration. It keeps Synth Shell's
other tools and existing aliases, and repeated runs do not duplicate the loader.
Edit `shell/starship.toml` to adjust the prompt. On a separate installation, rerun
setup to deploy edits. New shells retain Bash's standard prompt if Starship is missing.
To restore the previous setup, copy the reported `.bashrc.bak.*` backup over `.bashrc`
and open a new shell. Starship configuration and binaries can stay installed.

`eza` and the remaining synth-shell tools are initialized by `~/.bashrc`.
The existing aliases provide `ls`, `l`, `ll`, `la`, and `lt`; tmux
does not redefine them, so the same shell experience is preserved inside and
outside tmux. If those tools are unavailable on another machine, the shell
configuration falls back without affecting tmux startup.

For Starship machines, run `./scripts/setup.sh --skip-synth-shell` to provision
tmux/eza separately from the prompt. The legacy `./scripts/setup.sh` path
skips tools and aliases
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

Setup also repairs existing Synth Shell installs with the known separator bug
that displays `usernameE0B0` instead of a triangle. It backs up the prompt script
as `synth-shell-prompt.sh.bak.XXXXXXXX` and decodes only the separator, preserving
`separator_char='\uE0B0'` and treating prompt text literally. The repair matches
the affected renderer only; repeated runs leave the repaired script unchanged.

Use `--skip-synth-shell` to skip both installation and repair. Its installer runs
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
./tests/run.sh clipboard   # SSH routing and native-provider round trips
./tests/run.sh theme       # palette isolation and owner lifecycle
./tests/run.sh completion  # setup idempotence and optional real Tab/menu checks
```

`setup`, `prompt`, and `bindings` select the remaining focused groups. The default `all`
runs each group once. Theme checks compare fallback colours with the configured
defaults rather than enforcing a fixed palette.
Completion real-key tests use an installed ble.sh; to test a downloaded copy,
set `BECK_TEST_BLE_ROOT=/path/to/blesh`. Without ble.sh, the installer fixtures
still run and the real-key checks report their missing prerequisite.

Check the configuration without attaching to a live session:

```sh
TMUX_TMPDIR=/tmp/tmux-test tmux -L beck-check \
  -f ~/.config/tmux/tmux.conf new-session -d -s check
TMUX_TMPDIR=/tmp/tmux-test tmux -L beck-check kill-server
```

Reload an attached server with `C-s R`.

If an application was already running when the true-colour setting changed, start a
fresh pane (or restart the tmux server) so it inherits `COLORTERM=truecolor`.
