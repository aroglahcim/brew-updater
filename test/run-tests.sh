#!/bin/zsh
#
# run-tests.sh — exercise brew-update-check against fake brew and fake notifier.
#
# Nothing here touches Homebrew or the installed system. Every script invocation
# uses throwaway state, log, lock and runner paths inside a temporary directory
# whose name contains spaces, so quoting is exercised end to end.
#
# Usage: ./test/run-tests.sh

emulate -L zsh
setopt pipefail

readonly REPO_DIR=${0:A:h:h}
readonly CHECKER=$REPO_DIR/bin/brew-update-check
export PATH='/usr/bin:/bin:/usr/sbin:/sbin'

typeset -i FAILURES=0 TESTS=0

pass() {
	(( TESTS++ ))
	print -r -- "  ok   $1"
}

fail() {
	(( TESTS++ ))
	(( FAILURES++ ))
	print -r -- "  FAIL $1"
	if (( $# > 1 )); then
		print -r -- "       $2"
	fi
}

expect_eq() {
	local label=$1 actual=$2 expected=$3
	if [[ $actual == "$expected" ]]; then
		pass "$label"
	else
		fail "$label" "expected '$expected', got '$actual'"
	fi
}

# --- fixtures ---------------------------------------------------------------

# A brew stand-in driven by files in $FAKE_CONTROL: update_rc, outdated_rc, and
# outdated_json hold the scripted behaviour. Every invocation is appended to
# $FAKE_CONTROL/calls so tests can assert which commands ran.
write_fake_brew() {
	local target=$1
	cat >"$target" <<'EOF'
#!/bin/zsh
control=${FAKE_CONTROL:?}
print -r -- "$*" >>"$control/calls"
case $1 in
update)
	exit $(<"$control/update_rc")
	;;
outdated)
	rc=$(<"$control/outdated_rc")
	(( rc == 0 )) && cat "$control/outdated_json"
	exit $rc
	;;
*)
	print -r -- "fake brew: unexpected command: $*" >&2
	exit 99
	;;
esac
EOF
	chmod +x "$target"
}

# A terminal-notifier stand-in. Records each option one per line in
# $FAKE_CONTROL/notifier_calls and exits with $FAKE_CONTROL/notify_rc.
write_fake_notifier() {
	local target=$1
	cat >"$target" <<'EOF'
#!/bin/zsh
control=${FAKE_CONTROL:?}
print -r -- "---" >>"$control/notifier_calls"
local arg
for arg in "$@"; do
	print -r -- "$arg" >>"$control/notifier_calls"
done
exit $(<"$control/notify_rc")
EOF
	chmod +x "$target"
}

json_outdated() {
	# $1 = number of formulae, $2 = number of casks, $3 = number pinned
	local -i nf=$1 nc=$2 np=$3 i
	local out='{"formulae":['
	for (( i = 0; i < nf; i++ )); do
		(( i > 0 )) && out+=','
		if (( i < np )); then
			out+="{\"name\":\"f$i\",\"pinned\":true}"
		else
			out+="{\"name\":\"f$i\",\"pinned\":false}"
		fi
	done
	out+='],"casks":['
	for (( i = 0; i < nc; i++ )); do
		(( i > 0 )) && out+=','
		if (( i < np )); then
			out+="{\"token\":\"c$i\",\"pinned\":true}"
		else
			out+="{\"token\":\"c$i\",\"pinned\":false}"
		fi
	done
	out+=']}'
	print -r -- "$out"
}

setup_case() {
	local name=$1
	CASE_DIR="$TMPROOT/$name with spaces"
	mkdir -p "$CASE_DIR/state" "$CASE_DIR/logs" "$CASE_DIR/control"
	export FAKE_CONTROL=$CASE_DIR/control
	export BREW_UPDATER_STATE_DIR=$CASE_DIR/state
	export BREW_UPDATER_LOG_DIR=$CASE_DIR/logs
	export BREW_UPDATER_LOCK=$CASE_DIR/state/lock.d
	export BREW_UPDATER_BREW_BIN=$CASE_DIR/control/brew
	export BREW_UPDATER_NOTIFIER_BIN=$CASE_DIR/control/terminal-notifier
	export BREW_UPDATER_RUNNER_BIN="$CASE_DIR/bin dir/brew-update-run"

	write_fake_brew "$BREW_UPDATER_BREW_BIN"
	write_fake_notifier "$BREW_UPDATER_NOTIFIER_BIN"
	mkdir -p "${BREW_UPDATER_RUNNER_BIN:h}"

	print -r -- 0 >"$FAKE_CONTROL/update_rc"
	print -r -- 0 >"$FAKE_CONTROL/outdated_rc"
	print -r -- 0 >"$FAKE_CONTROL/notify_rc"
	json_outdated 0 0 0 >"$FAKE_CONTROL/outdated_json"
	: >"$FAKE_CONTROL/calls"
	: >"$FAKE_CONTROL/notifier_calls"
}

run_checker() {
	"$CHECKER" "$@" >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"
	print -r -- $?
}

# --- tests ------------------------------------------------------------------

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/brew-updater tests.XXXXXX")
cleanup() { rm -rf "$TMPROOT" }
trap 'cleanup' EXIT INT TERM

print -r -- "repo: $REPO_DIR"
print -r -- "tmp:  $TMPROOT"
print -r -- ''

# 1. No outdated packages.
print -r -- 'case: no outdated packages'
setup_case 'no-outdated'
rc=$(run_checker)
expect_eq 'exit code is 0' "$rc" 0
if [[ -f $BREW_UPDATER_STATE_DIR/notified-count ]]; then
	fail 'no notified count recorded'
else
	pass 'no notified count recorded'
fi
expect_eq 'no notification delivered' "$(<"$FAKE_CONTROL/notifier_calls")" $'---\n-remove\ncom.aroglahcim.brew-updater'
expect_eq 'brew update ran once' "$(grep -c '^update' "$FAKE_CONTROL/calls")" 1

# 2. Two formulae and one cask.
print -r -- 'case: two formulae and one cask'
setup_case 'some-outdated'
json_outdated 2 1 0 >"$FAKE_CONTROL/outdated_json"
rc=$(run_checker)
expect_eq 'exit code is 0' "$rc" 0
if grep -qx 'Homebrew: 3 updates available' "$FAKE_CONTROL/notifier_calls"; then
	pass 'title reports 3 updates'
else
	fail 'title reports 3 updates' "$(<"$FAKE_CONTROL/notifier_calls")"
fi
if grep -qF "$BREW_UPDATER_RUNNER_BIN" "$FAKE_CONTROL/notifier_calls"; then
	pass 'click target is the runner path'
else
	fail 'click target is the runner path' "$(<"$FAKE_CONTROL/notifier_calls")"
fi
expect_eq 'notified count recorded' "$(<"$BREW_UPDATER_STATE_DIR/notified-count")" 3

# 3. Pinned packages excluded.
print -r -- 'case: pinned packages are excluded'
setup_case 'pinned-only'
json_outdated 1 1 1 >"$FAKE_CONTROL/outdated_json"
rc=$(run_checker)
expect_eq 'exit code is 0' "$rc" 0
if grep -q 'updates available' "$FAKE_CONTROL/notifier_calls"; then
	fail 'no notification for pinned-only set' "$(<"$FAKE_CONTROL/notifier_calls")"
else
	pass 'no notification for pinned-only set'
fi

# 4. brew update fails.
print -r -- 'case: brew update fails'
setup_case 'update-fails'
print -r -- 1 >"$FAKE_CONTROL/update_rc"
rc=$(run_checker)
expect_eq 'exit code is 1' "$rc" 1
if [[ -f $BREW_UPDATER_STATE_DIR/notified-count ]]; then
	fail 'no notified count recorded'
else
	pass 'no notified count recorded'
fi

# 5. brew outdated fails.
print -r -- 'case: brew outdated fails'
setup_case 'outdated-fails'
print -r -- 1 >"$FAKE_CONTROL/outdated_rc"
rc=$(run_checker)
expect_eq 'exit code is 1' "$rc" 1
if [[ -f $BREW_UPDATER_STATE_DIR/notified-count ]]; then
	fail 'no notified count recorded'
else
	pass 'no notified count recorded'
fi

# 6. Notification delivery fails.
print -r -- 'case: notification delivery fails'
setup_case 'notify-fails'
json_outdated 1 0 0 >"$FAKE_CONTROL/outdated_json"
print -r -- 1 >"$FAKE_CONTROL/notify_rc"
rc=$(run_checker)
expect_eq 'exit code is 1' "$rc" 1
if [[ -f $BREW_UPDATER_STATE_DIR/notified-count ]]; then
	fail 'no notified count recorded'
else
	pass 'no notified count recorded'
fi

# 7. An unchanged count is not re-notified.
print -r -- 'case: unchanged count is suppressed'
setup_case 'second-run'
json_outdated 1 0 0 >"$FAKE_CONTROL/outdated_json"
run_checker >/dev/null
: >"$FAKE_CONTROL/notifier_calls"
rc=$(run_checker)
expect_eq 'exit code is 0' "$rc" 0
expect_eq 'brew ran again' "$(grep -c '^update' "$FAKE_CONTROL/calls")" 2
expect_eq 'no second notification' "$(<"$FAKE_CONTROL/notifier_calls")" ''
if grep -q 'already notified' "$CASE_DIR/stdout"; then
	pass 'reports already notified'
else
	fail 'reports already notified' "$(<"$CASE_DIR/stdout")"
fi

# 8. --force re-notifies an unchanged count.
print -r -- 'case: --force re-notifies'
setup_case 'force'
json_outdated 1 0 0 >"$FAKE_CONTROL/outdated_json"
run_checker >/dev/null
: >"$FAKE_CONTROL/notifier_calls"
rc=$(run_checker --force)
expect_eq 'exit code is 0' "$rc" 0
expect_eq 'brew update ran twice' "$(grep -c '^update' "$FAKE_CONTROL/calls")" 2
if grep -qx 'Homebrew: 1 update available' "$FAKE_CONTROL/notifier_calls"; then
	pass 'notification re-posted'
else
	fail 'notification re-posted' "$(<"$FAKE_CONTROL/notifier_calls")"
fi

# 9. A changed count notifies again.
print -r -- 'case: changed count notifies again'
setup_case 'count-changed'
json_outdated 1 0 0 >"$FAKE_CONTROL/outdated_json"
run_checker >/dev/null
json_outdated 2 0 0 >"$FAKE_CONTROL/outdated_json"
: >"$FAKE_CONTROL/notifier_calls"
rc=$(run_checker)
expect_eq 'exit code is 0' "$rc" 0
if grep -qx 'Homebrew: 2 updates available' "$FAKE_CONTROL/notifier_calls"; then
	pass 'notification for the new count'
else
	fail 'notification for the new count' "$(<"$FAKE_CONTROL/notifier_calls")"
fi
expect_eq 'notified count updated' "$(<"$BREW_UPDATER_STATE_DIR/notified-count")" 2

# 10. Concurrent run is refused.
print -r -- 'case: concurrent run'
setup_case 'concurrent'
json_outdated 1 0 0 >"$FAKE_CONTROL/outdated_json"
# Make brew update slow enough to overlap two invocations.
cat >"$FAKE_CONTROL/brew" <<'EOF'
#!/bin/zsh
control=${FAKE_CONTROL:?}
print -r -- "$*" >>"$control/calls"
case $1 in
update) sleep 2; exit 0 ;;
outdated) cat "$control/outdated_json"; exit 0 ;;
esac
EOF
chmod +x "$FAKE_CONTROL/brew"

"$CHECKER" >"$CASE_DIR/first.out" 2>&1 &
first_pid=$!
sleep 0.7
rc=$(run_checker)
wait "$first_pid"
expect_eq 'second instance exits 75' "$rc" 75
expect_eq 'brew update ran once' "$(grep -c '^update' "$FAKE_CONTROL/calls")" 1
if [[ -f $BREW_UPDATER_LOCK ]]; then
	fail 'lock released after both runs'
else
	pass 'lock released after both runs'
fi

# 11. A stale lock from a dead process is reclaimed.
print -r -- 'case: stale lock is reclaimed'
setup_case 'stale-lock'
mkdir -p "$BREW_UPDATER_LOCK"
print -r -- 999999 >"$BREW_UPDATER_LOCK/pid"
rc=$(run_checker)
expect_eq 'exit code is 0' "$rc" 0
if [[ -d $BREW_UPDATER_LOCK ]]; then
	fail 'stale lock removed'
else
	pass 'stale lock removed'
fi

# --- summary ----------------------------------------------------------------

print -r -- ''
print -r -- "tests: $TESTS, failures: $FAILURES"
(( FAILURES == 0 ))
