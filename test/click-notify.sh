#!/bin/zsh
#
# click-notify.sh — send a test notification whose click runs click-run.sh.
#
# Proves the notification click path (terminal-notifier -execute -> Terminal)
# without touching Homebrew. The click target is the harmless test script.
#
# Usage: ./test/click-notify.sh

emulate -L zsh
setopt pipefail

readonly REPO_DIR=${0:A:h:h}
export PATH='/usr/bin:/bin:/usr/sbin:/sbin'

readonly HOME_DIR=${HOME:?HOME is not set}
readonly NOTIFIER=${BREW_UPDATER_NOTIFIER_BIN:-/opt/homebrew/bin/terminal-notifier}
readonly TEST_RUNNER=$REPO_DIR/test/click-run.sh

if [[ ! -x $NOTIFIER ]]; then
	print -r -- "terminal-notifier not found at $NOTIFIER" >&2
	print -r -- 'install it with: brew install terminal-notifier' >&2
	exit 1
fi

if [[ ! -x $TEST_RUNNER ]]; then
	print -r -- "test runner not executable: $TEST_RUNNER" >&2
	exit 1
fi

if ! "$NOTIFIER" \
	-title 'brew-updater test' \
	-message 'Kliknij, aby sprawdzić akcję powiadomienia. Uruchomi się tylko test, nigdy brew upgrade.' \
	-subtitle 'Test kliknięcia, nie aktualizacja' \
	-group 'com.aroglahcim.brew-updater.selftest' \
	-execute "exec '$TEST_RUNNER'"; then
	rc=$?
	print -r -- "notification delivery failed (exit $rc)" >&2
	case $rc in
	3) print -r -- 'Notifications are not authorized. See the manual steps in README.md.' >&2 ;;
	4) print -r -- 'No GUI session; notifications need a logged-in desktop session.' >&2 ;;
	esac
	exit 1
fi

print -r -- 'test notification sent'
print -r -- "click target: $TEST_RUNNER"
print -r -- ''
print -r -- 'If it does not appear, run: terminal-notifier -diagnose'
