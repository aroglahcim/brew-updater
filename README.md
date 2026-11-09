# brew-updater

Homebrew update checker with a clickable macOS notification. The check runs in the
background every 30 minutes and never upgrades anything; clicking the notification
opens an interactive Terminal running `brew upgrade`.

Agents: read [`AGENTS.md`](AGENTS.md) for conventions and safety rules, and
[`CONTRACT.md`](CONTRACT.md) for the stable behaviour contract. The plan for
publishing through a Homebrew tap is in [`docs/PUBLISHING.md`](docs/PUBLISHING.md).

## Install

```sh
brew install terminal-notifier
./install.sh                 # calendar trigger at 07:00, plus every 30 min
./install.sh --time 06:30    # or pick a time
./install.sh --dry-run       # render and validate only
```

This links the scripts into `~/.local/bin`, renders the LaunchAgent into
`~/Library/LaunchAgents`, validates it with `plutil -lint`, and loads it with
`launchctl bootstrap gui/$UID`.

## Behaviour

- At login, at the configured time, and every 30 minutes all day, the agent runs
  `brew update` and `brew outdated --json=v2`.
- With no outdated packages, nothing is shown and any previous notification is
  removed.
- With outdated packages, one notification appears:
  `Dostępne aktualizacje: N. Kliknij, aby uruchomić brew upgrade.`
- Clicking it opens Terminal and runs `brew upgrade -y`, so no `Do you want to
  proceed?` prompt appears. The window stays open so the result can be read. A
  cask that needs a password prompts for it there.
- A notification is only re-posted when the outdated count changes, so the check
  stays quiet between runs. Clicking the notification clears that memory, so the
  next check re-posts it for whatever is still outdated.

## Status and logs

```sh
launchctl print gui/$(id -u)/com.aroglahcim.brew-updater
tail -f ~/Library/Logs/brew-updater/brew-updater.log
```

## Force a notification

```sh
~/.local/bin/brew-update-check --force
```

Checks as usual and posts the notification even when the count is unchanged.
## Tests

```sh
./test/run-tests.sh        # mock-driven, never touches Homebrew
./test/click-notify.sh     # notification whose click runs an echo, not brew
```

## Uninstall

```sh
./uninstall.sh             # unload agent, remove plist and symlinks
./uninstall.sh --purge     # also delete state and logs
```

## Notification permissions

The first notification may need approval. macOS only offers that prompt for a
bundle it can find in an Applications folder, so `install.sh` links
`terminal-notifier.app` into `~/Applications` for you.

1. Open **System Settings > Notifications**.
2. Find `terminal-notifier` and set the style to **Alerts** so the banner stays
   until dismissed and stays clickable.
3. Run `terminal-notifier -diagnose` to confirm `authorization granted`.

If it still reports `denied`, `terminal-notifier` itself prints the reset command.
This repository never runs it for you, because changing the macOS permission
database is out of scope.

## Click behaviour

The runner writes `~/.local/state/brew-updater/upgrade.command` and opens it with
`open -a Terminal`, so no Automation permission is involved. The script runs
`brew upgrade -y`, which skips the interactive confirmation. The window stays open
after the upgrade and shows the exit code.
