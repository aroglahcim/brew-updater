# Agent Guidelines — brew-updater

## Purpose

A single-user macOS utility that reports available Homebrew updates and lets the
user start the upgrade from a notification click.

- **Does:** refresh Homebrew metadata, count outdated formulae and casks, post one
  clickable notification, and on click open an interactive Terminal running
  `brew upgrade -y`.
- **Does not:** install or upgrade anything in the background, run `sudo`, change
  authorization databases, use `--greedy`, or act on package names taken from
  notification text or `brew` output.

Scope is this repository plus the files `install.sh` writes into `$HOME`. Nothing
here manages system-level daemons.

## Tooling

| Tool | Role |
|------|------|
| `zsh` | Script interpreter; all entry points are zsh with `emulate -L zsh` |
| `brew` | Homebrew CLI, resolved at runtime, never assumed to be in `/opt/homebrew` |
| `jq` | Parses `brew outdated --json=v2`; resolved from the Homebrew prefixes, then `/usr/bin/jq`, then `PATH` |
| `terminal-notifier` | Posts the notification and stores the click action |
| `open -a Terminal` | Opens the generated `.command` script through LaunchServices |
| `plutil` | Validates the rendered LaunchAgent plist |
| `launchctl` | Loads and unloads the user LaunchAgent |

Commands:

```sh
./install.sh --dry-run           # render and validate, change nothing
./install.sh --time 07:00        # install and load the LaunchAgent
./test/run-tests.sh              # mock-driven test suite
./test/click-notify.sh           # safe click-path test, never runs brew
./uninstall.sh --purge           # remove everything, including state and logs
```

There is no build step and no package manager.

## Conventions

- Every script starts with `emulate -L zsh` and sets a hard-coded minimal `PATH`.
  Never rely on interactive dotfiles; launchd does not load them.
- Absolute paths for system tools (`/bin/date`, `/usr/bin/jq`, `/bin/launchctl`).
  Optional tools are additionally looked up in the Homebrew prefixes, because the
  hard-coded `PATH` deliberately excludes them.
- Every filesystem path is quoted. Directories may contain spaces.
- State writes are atomic: write a temp file in the same directory, then `mv -f`.
- Prefer machine-readable `brew` output. Never parse decorated human-facing text.
- Exit codes are meaningful: `0` success, `1` failure, `75` lock contention.
- All strings, including user-facing ones, are English: code, comments, docs,
 notifications, and generated Terminal output.

## Safety — non-negotiable

- Never remove or modify Homebrew's own lock directory
  (`$(brew --prefix)/var/homebrew/locks`), and never kill another `brew` process.
- Never run `brew upgrade` from the checker. Only the click path starts an upgrade,
  and only in a visible interactive Terminal.
- Never run `sudo brew`, never configure NOPASSWD, never modify TCC or
  notification authorization.
- The notification click target is a fixed absolute runner path. Do not build it
  from package names or message text.
- Open Terminal through `open -a Terminal`, never through `osascript`/Apple Events.
- A failed `brew update`, a failed `brew outdated`, or a failed notification must
  not record a successful check, so the next scheduled run retries.
- Do not add `--greedy`; detection scope must stay equal to plain `brew upgrade`.

## Implementation guidance

- `pinned` packages are filtered in the checker because `brew outdated` lists them
  while `brew upgrade` skips them.
- The runner writes a static `.command` script into the state directory and opens
  it with `open -a Terminal`. `osascript`/Apple Events is deliberately avoided: it
  needs the Automation permission, which cannot be granted non-interactively and
  fails with `-1743` on a fresh machine.
- The generated script runs `brew upgrade -y`; `-y` (`--no-ask`) skips the
  interactive confirmation, so the click is the only decision point. It ends with
  `exec /bin/zsh -l` so the Terminal window stays open after the upgrade, showing
  the exit code.
- Keep the LaunchAgent to `RunAtLoad` + `StartInterval` + `StartCalendarInterval`.
  `brew services` cannot express both interval and calendar triggers in one job;
  see `CONTRACT.md`.
- `install.sh` symlinks the terminal-notifier app bundle into `~/Applications`.
  macOS resolves notification authorization through LaunchServices, which only
  scans `/Applications` and `~/Applications`; a Homebrew keg in `Cellar` is never
  offered in the permission prompt.
- Install modes: standalone via `install.sh` (current default), chezmoi external,
  or a Homebrew tap that calls `install.sh` from `post_install`. Do not invent a
  fourth.

## Key paths

| Path | Purpose |
|------|---------|
| `bin/brew-update-check` | Main checker invoked by launchd |
| `bin/brew-update-run` | Click target; opens Terminal and runs `brew upgrade -y` |
| `launchd/com.aroglahcim.brew-updater.plist.tmpl` | LaunchAgent template with `@@TOKEN@@` placeholders |
| `install.sh` | Symlinks, plist rendering, `launchctl bootstrap` |
| `uninstall.sh` | `launchctl bootout`, symlink, plist and `~/Applications` link removal, optional purge |
| `test/run-tests.sh` | Mock-driven suite; never touches real Homebrew |
| `test/click-notify.sh` | Sends a notification whose click runs `test/click-run.sh` |
| `docs/PUBLISHING.md` | Plan for distributing through a Homebrew tap |
| `$HOME/.local/state/brew-updater/notified-count` | Outdated count the user was last notified about |
| `$HOME/.local/state/brew-updater/lock.d` | Lock directory holding the owner PID |
| `$HOME/.local/state/brew-updater/upgrade.command` | Generated Terminal script for the upgrade |
| `$HOME/Library/Logs/brew-updater/brew-updater.log` | Rotating diagnostic log |
| `$HOME/Library/Logs/brew-updater/launchd.log` | launchd stdio capture |

## External references

- terminal-notifier README (click actions, `-group`, `-remove`, `-diagnose`):
  https://github.com/julienXX/terminal-notifier
- `launchd.plist` reference (StartCalendarInterval vs StartInterval):
  `man 5 launchd.plist`
- Homebrew `brew outdated --json=v2` and `brew upgrade` semantics:
  https://docs.brew.sh/Manpage
