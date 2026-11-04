# Model eval: reviewer prompts

Fixed texts for [PLAN.md](PLAN.md). Send them verbatim and replace only the `{{PLACEHOLDERS}}`. After filling, store each prompt in `$EVAL/prompts/` together with its sha256.

| Section | Used by | When |
|---|---|---|
| 1. Review | `grader-opus`, `grader-grok`, `reviewer-sonnet`, `reviewer-composer` | per batch of candidates |
| 2. Cross-check | `grader-opus`, `grader-grok` | as a follow-up in the same session, after both graders finish section 1 |
| 3. Adjudication | `adjudicator-sol` | disputed findings, one run per task |
| 4. Plan review | Opus, for the `grok-build-planrev` setup | between Grok's plan and its implementation |
| 5. Matching | Grok Build | reviewer experiment only |

Placeholders:
- `{{REPO}}`: the sandbox repo, for example `sinanawad/sbx-04`.
- `{{BATCH_ID}}`: for example `M1-b1`.
- `{{CANDIDATES}}`: one `cand/<label>` per line, in a random order per batch and per grader.
- `{{BRIEF}}`: the frozen brief, task part only, without the writer preamble.
- `{{GATES}}`: one line per candidate in the form `cand/<label>: build=pass tests=pass lint=fail (shellcheck SC2086 scripts/x.sh:12)`.
- `{{OUTPUT_RULE}}`:
  - Cursor agents: `Don't create, commit or push any files or branches; scratch files go under /tmp.`
  - Grok Build: `Also write the same JSON to ../{{BATCH_ID}}-<phase>.json, outside the repository; <phase> is p1 or p2.`

No reviewer pushes anything. Two reviewers of the same batch can run at the same time on one sandbox, so a pushed review branch would leak. Blondie reads Cursor output from the run's `result` (in `<run>.run.json`) and Grok output from the file.

---

## 1. Review (phase 1)

```text
You are an independent senior reviewer in a blind evaluation. Review each candidate implementation of one task.

Repository: {{REPO}}. Branch `main` is the base. Each candidate is a branch with one commit on top of `main`:
{{CANDIDATES}}

Every candidate's author received this brief:
<<<BRIEF
{{BRIEF}}
BRIEF>>>

The operator has already run these objective gates (build, the repository's own tests, linters). Don't repeat them unless you need to confirm or refute a specific finding:
{{GATES}}

Rules
1. Review each candidate on its own, against the brief, the repository's rules and conventions (README, neighbouring code), and correctness. Don't compare or rank candidates, and don't let one candidate's approach shape what you expect from another.
2. Don't guess or mention who or what wrote a candidate.
3. Report only problems in the candidate's change or problems it causes. Pre-existing problems in `main` are out of scope unless the change makes them worse.
4. A blocker or major needs a concrete failing scenario: the input, state or sequence of steps, and the wrong result it produces. If you can't give one, the finding is minor at most.
5. Verify where you can: run the code, a test or a small script, and say what you ran in `verified`. If you didn't run anything, set `verified` to "reasoning".
6. Don't modify candidate branches, open pull requests, trigger CI workflows, browse the web, or read other repositories.
7. Changes unrelated to the brief are a minor finding unless they break something.
8. For each candidate, mark every requirement R1..Rn in the brief as met, partial or not met.

Severity rubric
- blocker: it doesn't build, or its own tests fail; it breaks existing behaviour on a main path; it opens a security hole (secret exposure, code or command injection, a required check that can pass without running, broader privileges); it loses data.
- major: a realistic input or path behaves wrongly; a brief requirement is missing or wrong; a test would still pass if the code it tests were wrong (silent pass); it breaks an interface, file format, exit code or API contract; it fails open where the repository or brief requires failing closed. Must be fixed before merge.
- minor: an unlikely edge case; missing hardening; missing tests for a secondary path; a misleading message or doc; scope creep.
- nit: style, naming, wording.

Verdict per candidate
- merge-ready: no blocker, no major, no minor.
- approve-after-fixes: minors only.
- request-changes: at least one major.
- reject: at least one blocker, or the approach is wrong and needs a rewrite.

Output
Print your review as your final message inside one ```json fence. {{OUTPUT_RULE}} Use this schema exactly, with ids <label>-1, <label>-2 and so on:
{
  "batch_id": "{{BATCH_ID}}",
  "candidates": [
    {
      "label": "cand/xxxx",
      "verdict": "merge-ready | approve-after-fixes | request-changes | reject",
      "requirements": [{"req": "R1", "status": "met | partial | not-met", "note": "..."}],
      "findings": [
        {
          "id": "xxxx-1",
          "severity": "blocker | major | minor | nit",
          "category": "correctness | tests | security | compatibility | conventions | docs | scope",
          "file": "path", "line": 0,
          "summary": "one sentence",
          "failing_scenario": "input/sequence -> wrong result (required for blocker/major)",
          "verified": "command(s) run and result, or \"reasoning\""
        }
      ]
    }
  ]
}
```

## 2. Cross-check (phase 2)

Cursor: a follow-up in the same agent. Grok Build: a **fresh** session (its phase-1 session has already been wiped), whose prompt is the full §1 text, then `Your phase-1 review was:` and its own phase-1 JSON, then the text below.

```text
Phase 2 for batch {{BATCH_ID}}. Keep your phase-1 review as it is.

A. Another independent reviewer raised the blocker and major findings below. For each one, answer with one of:
   - "same:<your finding id>": it is the same problem as one of yours;
   - "agree:<severity>": a real problem you missed, with the severity you would give it under the rubric;
   - "disagree": not a real problem, or below major. Give the evidence (code, or a command and its output).
{{OTHER_FINDINGS}}

B. Known-issue checklist for this task. For each item and each candidate, answer present, absent or n/a, with one line of evidence (file:line or a command).
{{KNOWN_ISSUES}}

Don't change your phase-1 findings. Print one ```json fence as your final message. {{OUTPUT_RULE}}
{
  "batch_id": "{{BATCH_ID}}",
  "cross_check": [{"other_id": "yyyy-2", "answer": "same:yyyy-1 | agree:major | disagree", "evidence": "..."}],
  "known_issues": [{"label": "cand/xxxx", "issue": "K1", "status": "present | absent | n/a", "evidence": "..."}]
}
```

`{{OTHER_FINDINGS}}` lists every blocker and major from the other grader's phase 1 for this batch, one per line: `<id> | cand/<label> | <severity> | <file>:<line> | <summary> | <failing_scenario>`. `{{KNOWN_ISSUES}}` is the task's K-list from [TASKS.md](TASKS.md), one per line: `K1 (major): <text>`.

## 3. Adjudication

```text
You are adjudicating disputed findings from a blind code review. Repository: {{REPO}}. Base is `main`, and the candidates are `cand/<label>` branches. The brief:
<<<BRIEF
{{BRIEF}}
BRIEF>>>

Each disputed item below gives the finding and two reviewers' positions. For each item, check the code (run whatever you need) and decide whether the problem is real and how severe it is under this rubric:
- blocker: doesn't build or own tests fail; breaks a main path; security hole; data loss.
- major: wrong behaviour on a realistic path; missing or wrong brief requirement; silent-pass test; contract break; fail-open.
- minor: unlikely edge case, missing hardening, secondary-path tests, misleading docs, scope creep.
- nit: style.
Don't guess who wrote any candidate. Don't modify branches.

{{DISPUTED}}

Output one ```json fence:
{"adjudications": [{"id": "...", "real": true, "severity": "blocker | major | minor | nit", "evidence": "..."}]}
```

`{{DISPUTED}}` has one block per item: the finding line in the `{{OTHER_FINDINGS}}` format, then `Reviewer A: <answer + evidence>` and `Reviewer B: <answer + evidence>`.

## 4. Plan review (Opus, `grok-build-planrev` only)

```text
You are reviewing an implementation plan before any code is written. Repository: {{REPO}}, branch `main`. Read the code the plan relies on and check its assumptions. Don't write code, don't push anything, and don't open pull requests.

The task brief:
<<<BRIEF
{{BRIEF}}
BRIEF>>>

The plan:
<<<PLAN
{{PLAN}}
PLAN>>>

List the problems, most important first, at most 15: requirements missed or misread, wrong assumptions about the code, risky or fail-open designs, missing tests, and simpler alternatives. For each, give a severity (blocker, major, minor, nit; same meanings as in code review) and the concrete change to make. Reply only with the numbered list.
```

## 5. Matching (reviewer experiment)

```text
Two lists of review findings concern the same candidate branches. List C holds confirmed problems. List R comes from another reviewer. For each item in R, give the id of the item in C that describes the same underlying problem, or "none". One R item can match at most one C item. Judge by the underlying problem, not the wording. Reply with one ```json fence: {"matches": [{"r_id": "...", "c_id": "... | none"}]}

List C:
{{CONFIRMED}}

List R:
{{REVIEWER_FINDINGS}}
```
