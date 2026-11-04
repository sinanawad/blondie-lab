# Model eval: task brief template

Every writer gets exactly **Part A + Part B** as one prompt. It's the same text for every setup, and the only per-setup value is `{{CAP_MIN}}`, which is set by tier. The `grok-build-planrev` setup also gets the Part C addenda. Briefs are frozen (sha256 recorded in `tasks.csv`) before the first launch for the task, and never edited after that. If a brief has to change, every run of that task starts over.

## Part A: writer preamble (verbatim)

```text
You are implementing a change in this repository. Work autonomously: nobody will answer questions. If something is ambiguous, pick the most reasonable interpretation, note it under "Assumptions" in your final message, and carry on.

Rules
- Use only this repository's contents and the tools in your environment. You may install packages and tools you need to build and test.
- Don't browse the web or search the internet. Don't read other GitHub repositories, issues or pull requests, including upstream projects and forks. Don't add git remotes or fetch from any other remote.
- Don't trigger GitHub Actions workflows or any other remote CI.
- Make the smallest change that fully meets the requirements, in the style of the surrounding code. Add or update tests as the brief asks.
- Before you finish, run the verification commands in the brief and fix what fails.
- Commit your work on the current branch with a clear message. Don't open a pull request.
- Time limit: {{CAP_MIN}} minutes. A correct, tested change beats extras.

Final message: the files you changed, how you verified (commands and results), your assumptions, and known limitations.
```

## Part B: task brief skeleton

```text
# Task: {{TITLE}}

## Context
{{2-6 sentences: what the component does and where it lives. Facts a newcomer would get from the README or the code at the base commit. Nothing about the fix.}}

## Problem
{{The origin text from TASKS.md, quoted verbatim where TASKS.md says so: failing-run symptom, review comment, issue or plan section.}}

## Requirements
R1. {{observable behaviour: what must be true, not how to do it}}
R2. ...
Rn. Tests: {{which kind of tests are expected}}

## Out of scope
{{explicit exclusions, e.g. "bundles", "live Juju runs"}}

## Verification
Run before finishing:
{{commands; see the per-repo defaults below}}
```

Default verification commands. The same text goes to every setup.
- **blondie-lab tasks:**
  - `bash scripts/test-harness.sh` (must exit 0).
  - `shellcheck -x <changed shell files>`.
  - If workflows changed: `actionlint` (install version 1.7.12 if it's missing).
- **juju tasks:**
  - `make run-go-tests TEST_PACKAGES="<the packages you changed>"`.
  - `go vet` on the same packages.
  - If you changed API params or facades: `make rebuild-schema`, and commit the result.
  - Add: "Machines differ in memory. If a full build is killed, test the changed packages only."

## Part C: `grok-build-planrev` addenda

**C1, plan-only prompt** (first Grok session). Send Part A + Part B, then:

```text
Phase 1 of 2: plan only. Don't modify any files and don't commit. Read the code you need, then reply with an implementation plan: the files and functions to change, the behaviour per requirement, edge cases, the tests to add, and how you'll verify. At most 60 lines.
```

**C2, implement prompt** (the same Grok session, resumed with `-s <run_id>`):

```text
Phase 2 of 2. A reviewer commented on your plan (below). Use the comments you agree with, and note any you reject and why. Then implement the task under the rules and requirements already given, run the verification commands, and commit.

<<<PLAN REVIEW
{{OPUS_PLAN_REVIEW}}
PLAN REVIEW>>>
```

## Part D: rules for writing a brief

1. **Allowed sources:** the origin text named in [TASKS.md](TASKS.md), the base tree, and general knowledge of the component.
2. **Forbidden:** anything taken from the accepted change, from the task's own review findings (the K-list), or from later commits and PRs. The exception is a fix-round task such as the M3 fallback, where the review comments *are* the origin.
3. **Requirements say *what*, never *how*.** "Other users' models are cleaned up" is fine. "Use `juju models --all`" is not, unless the origin text itself says so and TASKS.md tells you to keep it.
4. Use the brief drafts in TASKS.md as written. Fill the SLOT ones under the same rules.
5. **Leak check:** before freezing a brief, run the prompt below once with Grok Build as `evalrunner`. Remove every sentence it flags, unless the sentence is quoted origin text. Record `leak_check=pass` in `tasks.csv`.

```text
Below is a task brief, then a list of known issues that a reviewer later found in a solution. Answer two questions. (1) Quote every sentence of the brief that tells the implementer how to avoid or fix one of the known issues, or reveals the intended solution, beyond what the problem statement itself implies. (2) Say whether any requirement is phrased as an implementation step rather than an observable behaviour. Reply as a JSON list of {"sentence": "...", "issue": "K#", "why": "..."}, or [] if there are none.

BRIEF:
{{BRIEF}}

KNOWN ISSUES:
{{KNOWN_ISSUES}}
```
