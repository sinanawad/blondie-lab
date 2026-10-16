# shellcheck shell=bash
# Shared helpers for the setup scripts (sourced, not executed).

# setup_fail <message>: record why setup failed (verdict.sh uses it as the
# setup-error reason), print a ::error:: line and exit 2.
setup_fail() {
	mkdir -p "${LAB_STATE_DIR:?}"
	# First failure wins: a later step can't overwrite the real cause.
	[[ -s $LAB_STATE_DIR/setup-error.txt ]] || printf '%s\n' "$*" >"$LAB_STATE_DIR/setup-error.txt"
	echo "::error::setup: $*"
	exit 2
}

# state_set <key> <value>: append to $LAB_STATE_DIR/juju.env (parsed by
# verdict.sh, never sourced). Values must be single-line; each key is written
# once (verdict.sh rejects a state file with a repeated key).
state_set() {
	[[ $1 =~ ^[a-z_]+$ && $2 != *$'\n'* ]] || setup_fail "state_set: bad key or value for $1"
	! grep -q "^$1=" "${LAB_STATE_DIR:?}/juju.env" 2>/dev/null || setup_fail "state_set: $1 already set"
	printf '%s=%s\n' "$1" "$2" >>"${LAB_STATE_DIR:?}/juju.env"
}

# state_get <key>: last value of key in juju.env, or empty.
state_get() {
	local f="${LAB_STATE_DIR:?}/juju.env"
	[[ -f $f ]] || return 0
	sed -n "s/^$1=//p" "$f" | tail -n 1
}

# hold_refresh <snap>: stop snapd from auto-refreshing the snap for the rest of
# the job (a refresh restarts the daemon mid-scenario, a false regression, and
# makes the recorded revision wrong). collect.sh compares revisions anyway.
hold_refresh() {
	timeout 60 sudo snap refresh --hold "$1" >/dev/null || setup_fail "snap refresh --hold $1 failed"
}

# record_substrate <snap>: hold refreshes and record the substrate snap's
# tracked channel and installed revision (verdict.substrate_snap). Called by the
# substrate setup step that installed it.
record_substrate() {
	local name=$1 rev channel
	hold_refresh "$name"
	rev=$(snap list "$name" | awk 'NR == 2 {print $3}')
	channel=$(snap info "$name" | sed -n 's/^tracking: *//p')
	[[ $rev =~ ^[0-9]+$ ]] || setup_fail "could not read the $name snap revision ('$rev')"
	state_set substrate_snap_name "$name"
	state_set substrate_snap_channel "$channel"
	state_set substrate_snap_revision "$rev"
	echo "substrate: $name rev $rev ($channel)"
}
