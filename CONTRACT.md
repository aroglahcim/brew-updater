# Contract — brew-updater

Stable facts that must stay consistent across agent sessions. Update this file
when these facts change; do not leave them only in chat.

## CLI

| Command | Contract |
|---------|----------|
| `brew-update-check [--force]` | Refresh metadata, count outdated packages, notify. `--force` posts the notification even when the count is unchanged. |
| `brew-update-run` | Open Terminal and run `brew upgrade -y`. No arguments are honoured. |

Exit codes for the checker:

| Code | Meaning |
|------|---------|
| `0` | Check completed: up to date, count unchanged, or notification delivered |
| `1` | Check failed: `brew update`, `brew outdated`, `jq` parsing, or notification delivery |
| `75` | Another instance holds the lock; launchd retries on the next interval |

Automation must treat `75` as temporary. Treating `1` as "no updates" is a bug.

## Notification guard

`$HOME/.local/state/brew-updater/notified-count` holds a single line: the
outdated count the user was last notified about.

- Written atomically: temp file in the same directory, then `mv -f`.
- Written **only** after a notification was delivered with exit 0. A failed
  notification delivery leaves the file untouched, so the 30-minute
  `StartInterval` retries.
- The checker always refreshes metadata and recounts. It posts a notification
  only when the count differs from the stored value, or when the file is
  missing. `--force` posts regardless.
- When the count is zero the file is removed and the stale notification is
  cleared.
- The click path (`brew-update-run`) removes the file after clearing the
  notification, so the next scheduled run re-posts it for the current count.

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
- Title `Homebrew: N updates available` (`update` when N is 1), message
  `Click to run brew upgrade.`, subtitle
  `Click opens Terminal and runs brew upgrade.`. The count lives in the title so
  the number is visible without expanding the banner.
- `-execute` holds `exec '<absolute runner path>'`. The leading `exec ` keeps the
  value's first character a letter, avoiding terminal-notifier's NSUserDefaults
  property-list parsing of a leading quote.
- The click target never contains package names, message text, or anything derived
  from `brew` output.
- When the count is zero, the checker calls `terminal-notifier -remove` with the
  same group so a stale notification does not linger.
- Delivery failure is a check failure: exit `1`, no notified count, retry later.

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
- The upgrade command is `brew upgrade -y`: `-y` (`--no-ask`) skips the
  `Do you want to proceed?` confirmation, so the click alone starts the upgrade.
- It ends with `exec /bin/zsh -l`, so the window remains open after the upgrade and
  the exit code stays visible.
- It also clears the notification and removes `notified-count`, so the next
  scheduled check re-posts the notification for whatever is still outdated.

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
| `StartInterval` | `1800` | refresh cadence all day, and catch-up after wake |
| `ProcessType` | `Background` | no interactive QoS |

**`brew services` cannot express this job.** In Homebrew 7.x `Service#interval`
emits `StartInterval` only for `run_type :interval`, and `#cron` emits
`StartCalendarInterval` only for `run_type :cron`. The types are mutually
exclusive, so a `brew services` job cannot carry both triggers. The plist is
therefore always rendered by `install.sh` (or a tap's `post_install`).

Every trigger runs the full check. Notifications are rate-limited by the
`notified-count` guard, not by suppressing the check itself, so a package that
becomes outdated mid-day is reported on the next 30-minute run.

Screen-unlock detection is out of scope. The schedule covers login, the calendar
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
- Suppressing checks; only notifications are rate-limited.
- Managing packages, taps, or the `Brewfile`.
- System-level LaunchDaemons or cron entries.
