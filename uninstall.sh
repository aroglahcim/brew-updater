#!/bin/zsh
#
# uninstall.sh — remove brew-updater for the current user.
#
# Unloads the LaunchAgent, removes the plist and the symlinks, and optionally
# deletes state and logs. Installed packages are never touched.
#
# Usage: ./uninstall.sh [--purge] [--dry-run]
#   --purge    also delete state and log directories
#   --dry-run  report what would be removed, change nothing

emulate -L zsh
setopt pipefail err_return

readonly PROG_NAME=${0:t}
readonly LABEL='com.aroglahcim.brew-updater'

export PATH='/usr/bin:/bin:/usr/sbin:/sbin'

readonly HOME_DIR=${HOME:?HOME is not set}
readonly BIN_DIR=$HOME_DIR/.local/bin
readonly AGENT_PLIST=$HOME_DIR/Library/LaunchAgents/$LABEL.plist
readonly STATE_DIR=${BREW_UPDATER_STATE_DIR:-$HOME_DIR/.local/state/brew-updater}
readonly LOG_DIR=${BREW_UPDATER_LOG_DIR:-$HOME_DIR/Library/Logs/brew-updater}
readonly NOTIFIER_APP=$HOME_DIR/Applications/terminal-notifier.app

typeset -i DRY_RUN=0 PURGE=0

usage() {
	print -r -- "usage: $PROG_NAME [--purge] [--dry-run]"
	print -r -- ''
	print -r -- 'Unloads the LaunchAgent and removes the plist and symlinks.'
	print -r -- ''
	print -r -- '  --purge    also delete the state and log directories'
	print -r -- '  --dry-run  report what would be removed without changing anything'
}

die() {
	print -r -- "$PROG_NAME: error: $*" >&2
	exit 1
}

say() {
	print -r -- "==> $*"
}

# install.sh links the terminal-notifier bundle into ~/Applications so macOS can
# offer the notification permission prompt. Remove that link on uninstall, but
# only when it is a symlink into a terminal-notifier keg: anything else at that
# path is the user's own and must survive. The keg itself belongs to Homebrew and
# is never touched here.
is_our_notifier_link() {
	[[ -L $NOTIFIER_APP ]] || return 1
	local target
	target=$(/usr/bin/readlink "$NOTIFIER_APP") || return 1
	[[ $target == *terminal-notifier* ]]
}

while (( $# )); do
	case $1 in
	--purge) PURGE=1; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	--help|-h) usage; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done

if (( DRY_RUN )); then
	say 'dry run: would bootout the LaunchAgent'
	[[ -f $AGENT_PLIST ]] && say "would remove: $AGENT_PLIST"
	say "would remove: $BIN_DIR/brew-update-check"
	say "would remove: $BIN_DIR/brew-update-run"
	if is_our_notifier_link; then
		say "would remove: $NOTIFIER_APP"
	fi
	if (( PURGE )); then
		say "would remove: $STATE_DIR"
		say "would remove: $LOG_DIR"
	fi
	exit 0
fi

say 'unloading LaunchAgent'
/bin/launchctl bootout "gui/$(/usr/bin/id -u)/$LABEL" 2>/dev/null || true

if [[ -f $AGENT_PLIST ]]; then
	say "removing $AGENT_PLIST"
	rm -f "$AGENT_PLIST"
fi

say 'removing symlinks'
for link in "$BIN_DIR/brew-update-check" "$BIN_DIR/brew-update-run"; do
	[[ -L $link ]] && rm -f "$link"
done

if is_our_notifier_link; then
	say "removing $NOTIFIER_APP"
	rm -f "$NOTIFIER_APP"
fi

if (( PURGE )); then
	say "removing $STATE_DIR"
	rm -rf "$STATE_DIR"
	say "removing $LOG_DIR"
	rm -rf "$LOG_DIR"
else
	print -r -- ''
	print -r -- "State kept: $STATE_DIR"
	print -r -- "Logs kept:  $LOG_DIR"
	print -r -- 'Re-run with --purge to delete them.'
fi

say 'done'
