#!/usr/bin/env bash
# Ref trust check (design §8, Q8), before any setup. For `ref` (build mode)
# and an explicit `tests_ref` (their code runs in the job, which can reach
# ACTIONS_RUNTIME_TOKEN whatever permissions: says):
#   ref is trusted only if its SHA is reachable from a protected fork release
#   branch: compare/<sha>...<branch> is ahead or identical for an anchor in
#   ref_anchors (4.1, 4.0) on ref_repo (sinanawad/juju). Both are hard-coded
#   constants, never inputs. An anchor is protected only when
#   rules/branches/<b> reports both deletion and non_fast_forward; anything
#   else (false, 404, 422) skips that anchor with no compare. Other API
#   errors fail closed. No matching anchor: a SHA reachable from fork 3.6
#   keeps the "3.6 ref builds not supported" rejection; otherwise the ref is
#   not trusted. main is not an anchor.
#   tests_ref stays on juju/juju: reachable from main, 4.1, 4.0 or 3.6.
#   ref only, after reachability:
#   1. core/version/version.go at the SHA says `const version = "4.`
#      (3.6 history before the 2026-06-26 merge base 605b3a1 is an ancestor of
#      4.0, so reachability alone admits it; 3.6 has no such file);
#   2. the Makefile has no jujud-snap-build target (controller-snap builds,
#      main/4.2, are not supported in v1).
# Authenticated (`gh api`, GH_TOKEN = the job token). Fail closed: any API
# error (timeout, 5xx, 403/429, malformed output) is exit 2 "trust check could
# not complete", never trusted. A rejection is exit 2 with its reason.
# Outputs: ref_sha, ref_version, ref_line (4.0, 4.1, ...), ref_repo, tests_ref_sha.
set -euo pipefail
export LC_ALL=C
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

OUT=${GITHUB_OUTPUT:-/dev/stdout}
ref=${LAB_REF:-}
tests_ref=${LAB_TESTS_REF:-}
[[ -n $ref || -n $tests_ref ]] || setup_fail "ref-trust: nothing to check (workflow bug)"
# Values were validated by validate.sh; re-check the shape so nothing odd
# reaches a URL even if this script is called on its own.
re_ref='^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$'
for v in "$ref" "$tests_ref"; do
	[[ -z $v || ($v =~ $re_ref && $v != *..*) ]] || setup_fail "ref-trust: unexpected ref value (workflow bug)"
done
command -v gh >/dev/null || setup_fail "trust check could not complete (gh not found)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# One deadline for the whole check, below the step's 3 min timeout, so a slow
# API ends with this script's own reason, not a generic step timeout (ref +
# tests_ref is up to 14 calls). Each call gets at most 20 s of what is left.
deadline=${LAB_TRUST_DEADLINE_S:-150}
[[ $deadline =~ ^[1-9][0-9]*$ ]] || setup_fail "ref-trust: LAB_TRUST_DEADLINE_S: unexpected value"

# ref (build mode) is trusted only from these fork branches. Constants, never inputs.
ref_repo=sinanawad/juju
ref_anchors=(4.1 4.0)

# api <what> <gh api args...>: stdout of a successful call in $tmp/body.
# Returns 0 on success, 1 on HTTP 404/422 (no such commit/file/ref); any
# other failure ends the script: trust check could not complete.
api() {
	local what=$1 rc=0 left t
	shift
	left=$((deadline - SECONDS))
	((left > 0)) || setup_fail "trust check could not complete ($what: ${deadline}s deadline reached)"
	t=$((left < 20 ? left : 20))
	timeout "$t" gh api "$@" >"$tmp/body" 2>"$tmp/err" || rc=$?
	((rc == 0)) && return 0
	if ((rc != 124)) && grep -qE '\(HTTP (404|422)\)' "$tmp/err"; then
		return 1
	fi
	local why
	if ((rc == 124)); then why="timed out after ${t}s"; else why=$(head -c 200 "$tmp/err" | tr -d '\r\n'); fi
	setup_fail "trust check could not complete ($what: $why)"
}

# resolve <name> <repo> <ref>: the commit SHA in $sha.
resolve() {
	if ! api "resolve $1" "repos/$2/commits/$3" --jq .sha; then
		setup_fail "$1 '$3': no such commit, tag or branch in $2"
	fi
	sha=$(cat "$tmp/body")
	[[ $sha =~ ^[0-9a-f]{40}$ ]] || setup_fail "trust check could not complete (resolve $1: malformed response)"
}

# reachable <repo> <sha> <branches...>: sets $via to the first branch the SHA is an
# ancestor of (or equal to); returns 1 if none. Not called in $(...), so an
# API failure inside ends the script.
reachable() {
	local repo=$1 s=$2 b st
	shift 2
	via=""
	for b in "$@"; do
		if ! api "compare with $b" "repos/$repo/compare/$s...$b?per_page=1" --jq .status; then
			continue # 404: no common history with this branch
		fi
		st=$(cat "$tmp/body")
		case $st in
		ahead | identical) via=$b; return 0 ;;
		behind | diverged) ;;
		*) setup_fail "trust check could not complete (compare with $b: unexpected status '$st')" ;;
		esac
	done
	return 1
}

# protected_branch <repo> <branch>: 0 when rules/branches reports both deletion
# and non_fast_forward, 1 for false, 404 or 422. Any other API error fails
# closed inside api.
protected_branch() {
	local repo=$1 b=$2
	if ! api "rules for $b" "repos/$repo/rules/branches/$b" \
		--jq 'any(.[]; .type == "deletion") and any(.[]; .type == "non_fast_forward")'; then
		return 1
	fi
	[[ $(<"$tmp/body") == true ]]
}

# raw_file <path> <sha>: file content in $tmp/body; returns 1 if missing.
raw_file() {
	api "read $1" -H "Accept: application/vnd.github.raw" "repos/$ref_repo/contents/$1?ref=$2"
}

if [[ -n $ref ]]; then
	resolve ref "$ref_repo" "$ref"
	ref_sha=$sha
	unprotected=()
	via=""
	for b in "${ref_anchors[@]}"; do
		if ! protected_branch "$ref_repo" "$b"; then
			unprotected+=("$b")
			continue
		fi
		if reachable "$ref_repo" "$ref_sha" "$b"; then
			break
		fi
	done
	if [[ -z $via ]]; then
		if reachable "$ref_repo" "$ref_sha" 3.6; then
			setup_fail "ref '$ref' ($ref_sha): 3.6 ref builds not supported (reachable only from 3.6; use juju_channel=3.6/<risk>)"
		fi
		anchor_list=$(printf '%s, ' "${ref_anchors[@]}")
		anchor_list=${anchor_list%", "}
		msg="ref '$ref' ($ref_sha): not reachable from a protected ${ref_repo} release branch (${anchor_list})"
		if ((${#unprotected[@]} > 0)); then
			list=$(printf '%s, ' "${unprotected[@]}")
			list=${list%", "}
			msg+="; unprotected: ${list}"
		fi
		setup_fail "$msg"
	fi
	echo "ref $ref -> $ref_sha (reachable from $via)"
	if ! raw_file core/version/version.go "$ref_sha"; then
		if raw_file version/version.go "$ref_sha" && grep -qE '^const version = "3\.' "$tmp/body"; then
			setup_fail "ref '$ref' ($ref_sha): 3.6 ref builds not supported (version/version.go says $(sed -n 's/^const version = "\([^"]*\)".*/\1/p' "$tmp/body" | head -n 1))"
		fi
		setup_fail "ref '$ref' ($ref_sha): no core/version/version.go, not a 4.x tree (v1 builds start at v4.0-beta4)"
	fi
	ref_version=$(sed -n 's/^const version = "\([^"]*\)".*/\1/p' "$tmp/body" | head -n 1)
	[[ $ref_version =~ ^4\.[0-9]+([.-][a-z0-9.]+)?$ ]] ||
		setup_fail "ref '$ref' ($ref_sha): core/version/version.go says '${ref_version:-no const version}', not 4.x"
	ref_line=$(grep -oE '^4\.[0-9]+' <<<"$ref_version")
	raw_file Makefile "$ref_sha" || setup_fail "ref '$ref' ($ref_sha): no Makefile at this commit"
	if grep -qE '^jujud-snap-build:' "$tmp/body"; then
		setup_fail "ref '$ref' ($ref_sha, $ref_version): controller-snap builds not supported in v1 (Makefile has jujud-snap-build)"
	fi
	state_set ref_sha "$ref_sha"
	state_set ref_version "$ref_version"
	state_set ref_repo "$ref_repo"
	{
		echo "ref_sha=$ref_sha"
		echo "ref_version=$ref_version"
		echo "ref_line=$ref_line"
		echo "ref_repo=$ref_repo"
	} >>"$OUT"
	echo "ref: trusted ($ref_version, line $ref_line)"
fi

if [[ -n $tests_ref ]]; then
	resolve tests_ref juju/juju "$tests_ref"
	tests_ref_sha=$sha
	if ! reachable juju/juju "$tests_ref_sha" main 4.1 4.0 3.6; then
		setup_fail "tests_ref '$tests_ref' ($tests_ref_sha): not reachable from juju/juju main, 4.1, 4.0 or 3.6 (fork-only or unknown commit), not trusted"
	fi
	echo "tests_ref_sha=$tests_ref_sha" >>"$OUT"
	echo "tests_ref $tests_ref -> $tests_ref_sha: trusted (reachable from $via)"
fi
