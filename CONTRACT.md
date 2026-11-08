# Contract — brew-updater

Stable facts that must stay consistent across agent sessions. Update this file
when these facts change; do not leave them only in chat.

## CLI

| Command | Contract |
|---------|----------|
| `brew-update-check [--force]` | Refresh metadata, count outdated packages, notify. `--force` ignores the once-per-day guard. |
| `brew-update-run` | Open Terminal and run `brew upgrade`. No arguments are honoured. |

Exit codes for the checker:

| Code | Meaning |
|------|---------|
| `0` | Check completed: up to date, or notification delivered |
| `1` | Check failed: `brew update`, `brew outdated`, `jq` parsing, or notification delivery |
| `75` | Another instance holds the lock; launchd retries on the next interval |

Automation must treat `75` as temporary. Treating `1` as "no updates" is a bug.

## Daily guard

`$HOME/.local/state/brew-updater/last-success` holds a single line: the date in
`YYYY-MM-DD` from `date +%F`.

- Written atomically: temp file in the same directory, then `mv -f`.
- Written **only** after the whole check succeeded, which means: `brew update`
  exit 0, `brew outdated` exit 0, parsed count valid, and — when the count is
  greater than zero — the notification delivered with exit 0.
- Any failure leaves the file untouched, so the 30-minute `StartInterval` retries.
- If the stored date equals today, the checker exits `0` without running `brew`
  and without posting a notification.

## Detection scope

Counted as `[(.formulae // [])[], (.casks // [])[]] | map(select(.pinned != true)) | length`
from `brew outdated --json=v2`.

- Formulae **and** casks, matching plain `brew upgrade`.
- `pinned == true` entries are excluded because `brew upgrade` skips them
  (`upgrade.rb` rejects pinned formulae). Reporting them would promise an upgrade
  that will not happen.
- `--greedy` is never passed, and `HOMEBREW_UPGRADE_GREEDY` /
  `HOMEBREW_UPGRADE_GREEDY_CASKS` are unset before every `brew` call, so the
  checker's scope cannot drift from the upgrade's scope through inherited env.

The count is the number of outdated packages, not a guarantee of how many
installs will happen; dependencies may pull in more.

## Notification

- `-group com.aroglahcim.brew-updater` — a new notification replaces the previous
  one instead of stacking.
- Title `Homebrew`, message `Dostępne aktualizacje: N. Kliknij, aby uruchomić brew upgrade.`,
  subtitle `Kliknięcie uruchomi brew upgrade w Terminalu`.
- `-execute` holds `exec '<absolute runner path>'`. The leading `exec ` keeps the
  value's first character a letter, avoiding terminal-notifier's NSUserDefaults
  property-list parsing of a leading quote.
- The click target never contains package names, message text, or anything derived
  from `brew` output.
- When the count is zero, the checker calls `terminal-notifier -remove` with the
  same group so a stale notification does not linger.
- Delivery failure is a check failure: exit `1`, no success date, retry later.

### Authorization requirements

macOS ties notification permission to a bundle that LaunchServices can resolve.
Two machine-level facts must hold:

1. The `terminal-notifier` app bundle must be reachable from `/Applications` or
   `~/Applications`. `install.sh` symlinks it to `~/Applications/terminal-notifier.app`
   and registers it with `lsregister`; a bundle only in `Cellar` never appears in
   System Settings and permission cannot be requested.
2. The user must approve the app once. Until then `terminal-notifier` exits `3`
   (`Notifications are not authorized`) and `-diagnose` reports `denied`.

Neither is bypassed programmatically. No TCC reset and no preference editing is
performed by any script in this repository.

## Click path

`brew-update-run` writes a static `.command` script and opens it with
`open -a Terminal`. LaunchServices starts Terminal; no Automation permission is
involved.

- `osascript` with Apple Events is **not** used: it requires the Automation
  permission and fails with `-1743` on a machine that has never granted it.
- The generated script contains only the quoted `brew` path from resolution, never
  a package name or notification text.
- It ends with `exec /bin/zsh -l`, so the window remains open after the upgrade and
  the exit code stays visible.

## Locking

`$HOME/.local/state/brew-updater/lock.d` is a **directory**; `mkdir` is the atomic
operation. It contains `pid` with the owner's PID.

- A lock whose PID is not a live process is treated as stale and removed.
- Release happens in a `trap` on `EXIT INT TERM HUP`, and only when this process
  acquired the lock.
- `shlock(1)` is not used: it is deprecated and refuses to clear a lock file whose
  mtime is under one second old, which made stale-lock recovery unreliable.
- The lock never touches `$(brew --prefix)/var/homebrew/locks` and never signals
  another process.

## Scheduler

One user LaunchAgent, `com.aroglahcim.brew-updater`, in `~/Library/LaunchAgents`,
loaded with `launchctl bootstrap gui/$UID`.

| Key | Value | Why |
|-----|-------|-----|
| `RunAtLoad` | `true` | check at login |
| `StartCalendarInterval` | `Hour`/`Minute`, default 07:00 | morning check; a missed fire runs after wake |
| `StartInterval` | `1800` | retry cadence, and catch-up after wake |
| `ProcessType` | `Background` | no interactive QoS |

**`brew services` cannot express this job.** In Homebrew 7.x `Service#interval`
emits `StartInterval` only for `run_type :interval`, and `#cron` emits
`StartCalendarInterval` only for `run_type :cron`. The types are mutually
exclusive, so a `brew services` job cannot carry both triggers. The plist is
therefore always rendered by `install.sh` (or a tap's `post_install`).

Screen-unlock detection is out of scope. The schedule covers login, the daily
time, and wake.

## Logs

`$HOME/Library/Logs/brew-updater/brew-updater.log`, one timestamped line per event,
with Homebrew output appended during `brew update`.

- Rotation at 256 KiB, keeping 3 compressed-free copies (`.1` … `.3`).
- Copy-then-truncate, not rename: launchd keeps the file descriptor open via
  `StandardOutPath`, so the inode must survive.
- `launchd.log` in the same directory captures the plist's stdio.

## Environment overrides

Every path is overridable so tests and alternate installs work without touching
the real state. Defaults:

| Variable | Default |
|----------|---------|
| `BREW_UPDATER_STATE_DIR` | `$HOME/.local/state/brew-updater` |
| `BREW_UPDATER_LOG_DIR` | `$HOME/Library/Logs/brew-updater` |
| `BREW_UPDATER_BREW_BIN` | resolved: `/opt/homebrew/bin/brew`, `/usr/local/bin/brew`, then `PATH` |
| `BREW_UPDATER_JQ_BIN` | `/usr/bin/jq`, then `PATH` |
| `BREW_UPDATER_NOTIFIER_BIN` | `/opt/homebrew/bin/terminal-notifier`, `/usr/local/bin/terminal-notifier`, then `PATH` |
| `BREW_UPDATER_RUNNER_BIN` | `$HOME/.local/bin/brew-update-run` |
| `BREW_UPDATER_LOCK` | `$STATE_DIR/lock.d` |

## Out of scope

- Background upgrades, upgrades triggered on a timer, and `sudo brew`.
- Greedy cask handling and `version :latest` casks.
- Detecting screen unlock.
- Managing packages, taps, or the `Brewfile`.
- System-level LaunchDaemons or cron entries.
