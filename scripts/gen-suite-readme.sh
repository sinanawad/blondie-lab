#!/usr/bin/env bash
# gen-suite-readme.sh <scenario> <juju tests dir>: (re)writes
# scenarios/<scenario>/README.md for a suite-backed scenario (design §5: the
# descriptions are generated from each suite's task.sh, so they don't drift).
# Inputs, all in scenarios/<scenario>/:
#   run.sh        must hold one `suite=<name>` line (the juju/juju suite) and,
#                 for k8s, a `cloud_args=(-c microk8s)` line;
#   skips.txt     `<test_name> <reason...>` per line (# comments allowed); the
#                 same file feeds run.sh's -s list, so README and run agree;
#   alone.txt     optional, same format: tests left out of the suite run (-s)
#                 and run on their own afterwards (`main.sh <suite> <test>`);
#   notes.md      optional hand-written section (teardown checks, budget);
#   scenario.env  SUBSTRATE, TIMEOUT_MIN, DEPS.
# From the tests tree: the test_* calls in suites/<suite>/task.sh (in order)
# and, per test, the `run "run_*"` subtests in its definition. The tree's
# commit (and tag, if HEAD is one) is written into the README. A task.sh line
# that calls test_* in any other form (arguments, `|| true`) is exit 2, so no
# test is silently left off the list.
# Run from the repo root, e.g. with a juju/juju checkout at the 4.0/stable
# snap's git-commit:  scripts/gen-suite-readme.sh relations ../juju/tests
#
# gen-suite-readme.sh --check <scenario>: offline (no juju tree needed), exit 1
# when the README no longer matches its inputs: the What line with the -s list,
# every skip/alone reason verbatim, the number of skipped/alone entries,
# notes.md, and the Budget line (TIMEOUT_MIN).
set -euo pipefail
export LC_ALL=C
check=0
if [[ ${1:-} == --check ]]; then
	check=1
	shift
fi
usage="usage: gen-suite-readme.sh <scenario> <juju tests dir> | --check <scenario>"
name=${1:?$usage}
dir="scenarios/$name"
[[ -f $dir/run.sh && -f $dir/scenario.env && -f $dir/skips.txt ]] || { echo "$dir: needs run.sh, scenario.env, skips.txt" >&2; exit 2; }
suite=$(sed -nE 's/^suite=([a-z0-9_]+)$/\1/p' "$dir/run.sh")
[[ -n $suite ]] || { echo "$dir/run.sh: no suite=<name> line" >&2; exit 2; }
cloud=""
grep -qE '^cloud_args=\(-c microk8s\)$' "$dir/run.sh" && cloud="-c microk8s "

env_get() { sed -nE "s/^$1=(.*)$/\\1/p" "$dir/scenario.env" | tail -n 1; }
substrate=$(env_get SUBSTRATE)
timeout_min=$(env_get TIMEOUT_MIN)
deps=$(env_get DEPS)

declare -A reason=() alone=()
skip_order=() alone_order=()
read_list() { # read_list <file> <order array name>
	local -n order=$2
	local t r
	while read -r t r; do
		[[ -z $t || $t == \#* ]] && continue
		[[ $t =~ ^test_[a-z0-9_]+$ && -n $r ]] || { echo "$1: bad line '$t $r'" >&2; exit 2; }
		[[ -z ${reason[$t]:-} ]] || { echo "$1: $t is listed twice" >&2; exit 2; }
		reason[$t]=$r
		order+=("$t")
	done <"$1"
}
read_list "$dir/skips.txt" skip_order
[[ ! -f $dir/alone.txt ]] || read_list "$dir/alone.txt" alone_order
for t in "${alone_order[@]}"; do alone[$t]=1; done
skips=$(
	IFS=,
	all=("${skip_order[@]}" "${alone_order[@]}")
	echo "${all[*]}"
)
what="juju/juju \`tests/main.sh -l \"\$LAB_CONTROLLER\" ${cloud}${skips:+-s $skips }$suite\`"
for t in "${alone_order[@]}"; do
	what+=", then \`tests/main.sh -l \"\$LAB_CONTROLLER\" ${cloud}$suite $t\`"
done
what_line="- **What:** $what against the lab controller (\`SUBSTRATE=$substrate\`${deps:+, \`DEPS=$deps\`})."
budget="- **Budget:** \`TIMEOUT_MIN=$timeout_min\` per iteration (calibration: \`docs/calibration.md\`)."

if ((check)); then
	readme="$dir/README.md"
	[[ -f $readme ]] || { echo "$readme: missing (run scripts/gen-suite-readme.sh $name <juju tests dir>)"; exit 1; }
	bad=0
	grep -qxF -- "$what_line" "$readme" || { echo "$readme: What line (-s list) doesn't match skips.txt/alone.txt/scenario.env"; bad=1; }
	for t in "${skip_order[@]}" "${alone_order[@]}"; do
		grep -qF -- "${reason[$t]}" "$readme" || { echo "$readme: the reason for $t differs from skips.txt/alone.txt"; bad=1; }
	done
	# shellcheck disable=SC2016 # backticks are literal README markdown
	n=$(grep -cE '^  - (~~`test_[a-z0-9_]+`~~ \*\*skipped\*\*|`test_[a-z0-9_]+` (is skipped but not in this tree|\*\*runs alone\*\*))' "$readme" || true)
	want=$((${#skip_order[@]} + ${#alone_order[@]}))
	((n == want)) || { echo "$readme: $n skipped/alone entries, the inputs have $want"; bad=1; }
	if [[ -f $dir/notes.md ]]; then
		while IFS= read -r l; do
			[[ -z $l ]] || grep -qxF -- "$l" "$readme" || { echo "$readme: notes.md line missing: ${l:0:60}..."; bad=1; break; }
		done <"$dir/notes.md"
	fi
	grep -qxF -- "$budget" "$readme" || { echo "$readme: Budget line doesn't match TIMEOUT_MIN=$timeout_min"; bad=1; }
	((bad == 0)) && echo "$readme: matches its inputs"
	exit "$bad"
fi

tests=${2:?$usage}
task="$tests/suites/$suite/task.sh"
[[ -f $task ]] || { echo "$task: not found" >&2; exit 2; }

# test_* calls in the suite's top-level test function, in order.
mapfile -t list < <(sed -nE 's/^[[:space:]]+(test_[a-z0-9_]+)[[:space:]]*$/\1/p' "$task")
((${#list[@]} > 0)) || { echo "$task: no test_* calls found" >&2; exit 2; }
odd=$(grep -nE '^[[:space:]]+test_' "$task" | grep -vE '^[0-9]+:[[:space:]]+test_[a-z0-9_]+[[:space:]]*$' || true)
[[ -z $odd ]] || { echo "$task: test_* call(s) in a form this parser can't list: $odd" >&2; exit 2; }
# subtests <test>: the run "run_*" lines in that test's definition.
subtests() {
	awk -v f="$1() {" '$0 == f {on = 1; next} on && /^}/ {exit} on {
		if (match($0, /run "run_[a-z0-9_]+"/)) { s = substr($0, RSTART + 5, RLENGTH - 6); printf "%s%s", sep, s; sep = ", " } }' \
		"$tests/suites/$suite"/*.sh
}
commit=$(git -C "$tests" rev-parse HEAD 2>/dev/null || echo unknown)
tag=$(git -C "$tests" describe --tags --exact-match 2>/dev/null || true)

{
	echo "# $name"
	echo
	echo "<!-- Generated by scripts/gen-suite-readme.sh from juju/juju tests at ${commit}${tag:+ ($tag)}; edit skips.txt / alone.txt / notes.md, not this file. -->"
	echo
	echo "$what_line"
	echo "- **Tests** (from \`suites/$suite/task.sh\` at \`${commit:0:12}\`${tag:+, $tag}):"
	for t in "${list[@]}"; do
		s=$(subtests "$t")
		if [[ -n ${alone[$t]:-} ]]; then
			echo "  - \`$t\` **runs alone** after the suite${s:+ ($s)}: ${reason[$t]}"
		elif [[ -n ${reason[$t]:-} ]]; then
			echo "  - ~~\`$t\`~~ **skipped**${s:+ ($s)}: ${reason[$t]}"
		else
			echo "  - \`$t\`${s:+ ($s)}"
		fi
	done
	for t in "${skip_order[@]}" "${alone_order[@]}"; do
		printf '%s\n' "${list[@]}" | grep -qx -- "$t" && continue
		echo "  - \`$t\` is skipped but not in this tree (present on other branches): ${reason[$t]}"
	done
	if [[ -f $dir/notes.md ]]; then
		echo
		cat "$dir/notes.md"
	fi
	echo
	echo "$budget"
} >"$dir/README.md"
echo "wrote $dir/README.md (${#list[@]} tests, ${#skip_order[@]} skips, ${#alone_order[@]} alone)"
