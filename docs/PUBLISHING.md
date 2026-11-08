# Publishing through a Homebrew tap

Not implemented yet. This document records the intended shape so a later session
does not have to rediscover it. The current and supported install path is
`./install.sh` from a checkout, or a chezmoi external pointing at this repository.

## Target experience

```sh
brew tap arog-lahcim/tap
brew install arog-lahcim/tap/brew-updater
```

## Repository layout

A separate repository `homebrew-tap`:

```
homebrew-tap/
  Formula/
    brew-updater.rb
  .github/
    workflows/
      tests.yml
      publish.yml
  README.md
```

## Formula

The formula installs the same artefacts `install.sh` links today, then delegates
setup to `install.sh` so there is one installation logic:

```ruby
class BrewUpdater < Formula
  desc "Daily Homebrew update check with a clickable macOS notification"
  homepage "https://github.com/arog-lahcim/brew-updater"
  url "https://github.com/arog-lahcim/brew-updater/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_ME"
  license "MIT"

  depends_on "terminal-notifier"
  depends_on :macos

  def install
    bin.install "bin/brew-update-check", "bin/brew-update-run"
    pkgshare.install "launchd", "install.sh", "uninstall.sh"
  end

  def post_install
    system pkgshare/"install.sh", "--bin-dir", bin, "--from-prefix"
  end

  def caveats
    <<~EOS
      The LaunchAgent was installed for the current user.
      Check notification permissions for terminal-notifier and run:
        terminal-notifier -diagnose
    EOS
  end

  test do
    assert_match "usage:", shell_output("#{bin}/brew-update-check --help")
  end
end
```

Notes on this sketch:

- `install.sh` would need two extra flags for the tap path: an explicit bin
  directory and a mode that points the plist at `opt/brew-updater/bin` rather than
  `~/.local/bin`. Without them `post_install` would link into the wrong place.
- `post_install` is best-effort: Homebrew may run it without a GUI session. The
  caveats must therefore tell the user how to load the agent manually.
- `service do` would be tempting, but see the limitation below.

## Why `brew services` cannot carry this schedule

Verified in Homebrew 7.0.12 (`Library/Homebrew/service.rb`):

- `StartInterval` is emitted only when `run_type == :interval` (line 624).
- `StartCalendarInterval` is emitted only when `run_type == :cron` (line 658).

The two run types are mutually exclusive, so a single `brew services` job cannot
have both a 07:00 calendar trigger and a 30-minute retry interval. This tool needs
both. The plist therefore always comes from `install.sh`, and `brew services` is at
most a convenience for the interval-only variant:

```ruby
service do
  run [opt_bin/"brew-update-check"]
  run_type :interval
  interval 1800
end
```

Using that alone would lose the morning trigger, so it is not the default.

## Bottles via GitHub Actions

Homebrew's own workflow templates are the reference; the shape is:

`tests.yml` — run on pull requests:

```yaml
name: brew test-bot
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test-bot:
    strategy:
      matrix:
        os: [macos-14, macos-15]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: Homebrew/actions/setup-homebrew@master
      - run: brew test-bot --only-cleanup-before
      - run: brew test-bot --only-setup
      - run: brew test-bot --only-tap-syntax
      - run: brew test-bot --only-formulae
```

`publish.yml` — on a tag, build and attach bottles:

```yaml
name: brew pr-pull
on:
  push:
    tags: ["v*"]
jobs:
  bottle:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: Homebrew/actions/setup-homebrew@master
      - run: brew test-bot --only-formulae --root-url=https://ghcr.io/v2/arog-lahcim/tap
      - uses: actions/upload-artifact@v4
        with:
          path: bottles
```

Then pull the artefacts into the tap with `brew pr-pull`, or land them by hand with
`brew bottle`. Bottles are per macOS major, so each supported macOS needs its own
(`arm64_golden_gate`, `arm64_tahoe`, and so on). `brew test-bot` is the supported
way to produce them; hand-rolled `xcodebuild` is not.

## Versioning

- Tag `vX.Y.Z`; the formula's `url` points at the GitHub tag archive and its
  `sha256` changes with every release.
- `livecheck` block optional; a manual `url`/`sha256` bump per release is enough at
  this size.
- `head "https://github.com/arog-lahcim/brew-updater.git", branch: "main"` gives a
  development install for testing a tap without tagging.

## Known trade-off

Once installed through the tap, `brew upgrade` updates the updater itself. The tool
would then monitor its own release cycle. That is acceptable but must be stated in
the tap's README, since a broken release could silence the notification path.

## Open questions for that step

- Public or private tap? A private tap cannot be used by `brew` without
  authentication configuration.
- Formula only, or formula plus bottles from day one?
- Does the tap also install the LaunchAgent, or leave that to `install.sh` run by
  the user? `post_install` without a GUI session cannot always bootstrap the agent.
