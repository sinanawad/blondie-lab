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
