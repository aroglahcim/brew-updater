#!/bin/zsh
#
# click-run.sh — harmless stand-in for the click target during notification tests.
#
# Opens Terminal on a generated .command file that only prints text and a date.
# It never runs brew. Used to prove the click action reaches Terminal.

emulate -L zsh
setopt pipefail

export PATH='/usr/bin:/bin:/usr/sbin:/sbin'
cd /

readonly HOME_DIR=${HOME:?HOME is not set}
readonly LOG_DIR=${BREW_UPDATER_LOG_DIR:-$HOME_DIR/Library/Logs/brew-updater}
readonly STATE_DIR=${BREW_UPDATER_STATE_DIR:-$HOME_DIR/.local/state/brew-updater}
readonly TASK=$STATE_DIR/click-test.command

mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null
print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') [click-run] test click activated" >>"$LOG_DIR/brew-updater.log" 2>/dev/null

{
	print -r -- '#!/bin/zsh'
	print -r -- "print -r -- 'brew-updater test click: akcja -execute dociera do Terminala.'"
	print -r -- "print -r -- 'Nic nie zostalo zainstalowane ani zaktualizowane.'"
	print -r -- '/bin/date'
	print -r -- 'exec /bin/zsh -l'
} >"$TASK" 2>/dev/null || exit 1
chmod 700 "$TASK"

/usr/bin/open -a Terminal "$TASK" 2>/dev/null
