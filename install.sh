#!/bin/zsh
#
# install.sh — install brew-updater for the current user.
#
# Creates symlinks in ~/.local/bin, renders the LaunchAgent into
# ~/Library/LaunchAgents with this machine's absolute paths, validates the
# result, and loads it into the GUI session with launchctl bootstrap.
#
# Usage: ./install.sh [--time HH:MM] [--bin-dir DIR] [--dry-run]
#   --time HH:MM   time for the calendar trigger, 24h clock (default 07:00)
#   --bin-dir DIR  use DIR instead of ~/.local/bin, and do not create symlinks;
#                  a Homebrew tap already installed the executables there
#   --dry-run      render and validate, print the plan, change nothing

emulate -L zsh
setopt pipefail err_return

readonly PROG_NAME=${0:t}
readonly LABEL='com.aroglahcim.brew-updater'
readonly REPO_DIR=${0:A:h}

export PATH='/usr/bin:/bin:/usr/sbin:/sbin'

readonly HOME_DIR=${HOME:?HOME is not set}
readonly DEFAULT_BIN_DIR=$HOME_DIR/.local/bin
readonly AGENT_DIR=$HOME_DIR/Library/LaunchAgents
readonly AGENT_PLIST=$AGENT_DIR/$LABEL.plist
readonly STATE_DIR=${BREW_UPDATER_STATE_DIR:-$HOME_DIR/.local/state/brew-updater}
readonly LOG_DIR=${BREW_UPDATER_LOG_DIR:-$HOME_DIR/Library/Logs/brew-updater}
readonly TEMPLATE=$REPO_DIR/launchd/$LABEL.plist.tmpl

typeset -i DRY_RUN=0
typeset -i TIME_H=7 TIME_M=0
# Empty means the default layout: symlink our own executables into ~/.local/bin.
typeset BIN_DIR_OVERRIDE=''

usage() {
	print -r -- "usage: $PROG_NAME [--time HH:MM] [--bin-dir DIR] [--dry-run]"
	print -r -- ''
	print -r -- 'Installs symlinks in ~/.local/bin, renders and loads the LaunchAgent.'
	print -r -- ''
	print -r -- '  --time HH:MM   time for the calendar trigger, 24h clock (default 07:00)'
	print -r -- '  --bin-dir DIR  use DIR instead of ~/.local/bin, and do not create symlinks'
	print -r -- '  --dry-run      validate and report without changing anything'
}

die() {
	print -r -- "$PROG_NAME: error: $*" >&2
	exit 1
}

say() {
	print -r -- "==> $*"
}

# Escape a value for an XML text node.
xml_escape() {
	local value=$1
	value=${value//&/&amp;}
	value=${value//</&lt;}
	value=${value//>/&gt;}
	print -r -- "$value"
}

# Make the installed terminal-notifier app reachable from ~/Applications and ask
# LaunchServices to notice it. Without this the app never appears under System
# Settings > Notifications, so permission cannot be granted.
register_notifier_bundle() {
	local source_app
	# Do not rely on PATH here: install.sh runs with a deliberately minimal PATH.
	if [[ -d /opt/homebrew/opt/terminal-notifier/terminal-notifier.app ]]; then
		source_app=/opt/homebrew/opt/terminal-notifier/terminal-notifier.app
	elif [[ -d /usr/local/opt/terminal-notifier/terminal-notifier.app ]]; then
		source_app=/usr/local/opt/terminal-notifier/terminal-notifier.app
	else
		say 'warning: terminal-notifier not installed; notification permission cannot be requested'
		say '         install it with: brew install terminal-notifier'
		return 0
	fi

	mkdir -p "$HOME_DIR/Applications"
	ln -sfn "$source_app" "$HOME_DIR/Applications/terminal-notifier.app"
	say "linked notification app: $HOME_DIR/Applications/terminal-notifier.app"

	local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
	if [[ -x $lsregister ]]; then
		"$lsregister" -f "$HOME_DIR/Applications/terminal-notifier.app" >/dev/null 2>&1 || true
	fi
}

while (( $# )); do
	case $1 in
	--time)
		[[ -n ${2:-} ]] || die '--time requires HH:MM'
		[[ $2 == <->:<-> ]] || die "invalid time: $2 (expected HH:MM)"
		TIME_H=${2%%:*}
		TIME_M=${2##*:}
		[[ $TIME_H == <-> ]] && (( TIME_H >= 0 && TIME_H <= 23 )) || die "invalid hour: $TIME_H"
		[[ $TIME_M == <-> ]] && (( TIME_M >= 0 && TIME_M <= 59 )) || die "invalid minute: $TIME_M"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--bin-dir)
		[[ -n ${2:-} ]] || die '--bin-dir requires a directory'
		[[ $2 == /* ]] || die "invalid directory: $2 (expected an absolute path)"
		BIN_DIR_OVERRIDE=$2
		shift 2
		;;
	--help|-h)
		usage
		exit 0
		;;
	*)
		die "unknown argument: $1"
		;;
	esac
done

[[ -f $TEMPLATE ]] || die "template not found: $TEMPLATE"
[[ -x $REPO_DIR/bin/brew-update-check ]] || die "checker not executable: $REPO_DIR/bin/brew-update-check"
[[ -x $REPO_DIR/bin/brew-update-run ]] || die "runner not executable: $REPO_DIR/bin/brew-update-run"

if [[ -n $BIN_DIR_OVERRIDE ]]; then
	readonly BIN_DIR=$BIN_DIR_OVERRIDE
else
	readonly BIN_DIR=$DEFAULT_BIN_DIR
fi

say "repository: $REPO_DIR"
say "calendar trigger: $(printf '%02d:%02d' $TIME_H $TIME_M)"
say 'repeat interval: 1800s (30 min), all day'

rendered=$(<"$TEMPLATE")
rendered=${rendered//@@LABEL@@/$(xml_escape "$LABEL")}
rendered=${rendered//@@CHECKER@@/$(xml_escape "$BIN_DIR/brew-update-check")}
rendered=${rendered//@@LOG@@/$(xml_escape "$LOG_DIR")}
rendered=${rendered//@@TIME_H@@/$TIME_H}
rendered=${rendered//@@TIME_M@@/$TIME_M}

# The checker resolves the click target from BREW_UPDATER_RUNNER_BIN, falling
# back to ~/.local/bin. A tap puts the runner in opt/<formula>/bin, so the agent
# has to carry the path explicitly. The default layout needs no entry: the
# checker's own default already points at the symlink.
if [[ -n $BIN_DIR_OVERRIDE ]]; then
	environment=$(
		print -r -- '	<key>EnvironmentVariables</key>'
		print -r -- '	<dict>'
		print -r -- '		<key>BREW_UPDATER_RUNNER_BIN</key>'
		print -r -- "		<string>$(xml_escape "$BIN_DIR/brew-update-run")</string>"
		print -r -- '	</dict>'
	)
else
	environment=''
fi
rendered=${rendered//@@ENVIRONMENT@@/$environment}

if [[ $rendered == *@@* ]]; then
	die 'unsubstituted template token remains in rendered plist'
fi

if (( DRY_RUN )); then
	say 'rendered LaunchAgent:'
	print -r -- "$rendered"
	say 'dry run: nothing was changed'
	exit 0
fi

mkdir -p "$AGENT_DIR" "$STATE_DIR" "$LOG_DIR"

if [[ -z $BIN_DIR_OVERRIDE ]]; then
	mkdir -p "$BIN_DIR"
	say "linking into $BIN_DIR"
	ln -sfn "$REPO_DIR/bin/brew-update-check" "$BIN_DIR/brew-update-check"
	ln -sfn "$REPO_DIR/bin/brew-update-run" "$BIN_DIR/brew-update-run"
else
	say "using executables from $BIN_DIR (no symlinks created)"
fi

# macOS resolves UserNotification authorization through LaunchServices, which only
# scans /Applications and ~/Applications. A Homebrew keg lives in Cellar, so the
# bundle must be reachable from an Applications directory or the notification
# permission can never be requested.
register_notifier_bundle

say "rendering $AGENT_PLIST"
typeset tmp_plist="$AGENT_PLIST.tmp.$$"
print -r -- "$rendered" >"$tmp_plist"

if ! /usr/bin/plutil -lint "$tmp_plist" >/dev/null; then
	rm -f "$tmp_plist"
	die 'rendered plist failed plutil -lint'
fi
say 'plist validation: OK'

mv -f "$tmp_plist" "$AGENT_PLIST"

say 'unloading any previous instance'
/bin/launchctl bootout "gui/$(/usr/bin/id -u)/$LABEL" 2>/dev/null || true

# bootout is asynchronous; bootstrapping too early fails with EIO. Retry briefly.
say 'loading LaunchAgent'
typeset -i attempt bootstrapped=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
	if /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$AGENT_PLIST" 2>/dev/null; then
		bootstrapped=1
		break
	fi
	# A previous bootstrap may already have succeeded; treat a present job as success.
	if /bin/launchctl print "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1; then
		bootstrapped=1
		break
	fi
	sleep 0.5
done
(( bootstrapped )) || die 'launchctl bootstrap failed'

say 'done'
print -r -- ''
print -r -- "Status:  launchctl print gui/$(/usr/bin/id -u)/$LABEL"
print -r -- "Logs:    tail -f $LOG_DIR/brew-updater.log"
print -r -- "Check now: $BIN_DIR/brew-update-check --force"
print -r -- ''
print -r -- 'If notifications do not appear: System Settings > Notifications > terminal-notifier,'
print -r -- 'set the style to Alerts, and run: terminal-notifier -diagnose'
