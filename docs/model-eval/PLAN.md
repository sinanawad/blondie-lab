# Model and setup evaluation for Blondie's coding work

**Status:** final plan, v1. It replaces Joro's draft. **Owner:** Sinan. **Operator:** Blondie (bot name `blondie`). **Start:** Saturday 17 Oct 2026, Sofia time.

Files in this folder:
- `PLAN.md` (this file): purpose, design, changes from the draft, and the runbook.
- [TASKS.md](TASKS.md): the tasks, with base, accepted and historic refs, brief sources, known issues and hidden checks.
- [TASK_BRIEF_TEMPLATE.md](TASK_BRIEF_TEMPLATE.md): the writer prompt.
- [REVIEWER_PROMPT.md](REVIEWER_PROMPT.md): the grader, cross-check, adjudicator, plan-review and matching prompts, plus the severity rubric.

## 1. Purpose

The question: **for each tier of work (easy, medium, hard), which writer setup and which reviewer setup produce PR-ready changes at the lowest Cursor spend?** The answer comes from blind-graded output on real past tasks whose accepted result is known.

Why now:
- Every Blondie PR reviewed by an Opus 5.5 agent had findings.
- In this repo, Opus reviewed eight first drafts (#1–#8) and tagged about **1 blocker, 19 major, 40 minor and 14 nit** findings. These counts come from the severity word that opens each top-level review comment. Six of the eight drafts had at least one major.
- Cursor Ultra usage reached 80% in two days.
- SuperGrok gives a separate budget through Grok Build.

The deliverable is a short rulebook: tier → writer setup + reviewer setup + review policy, with the numbers behind each choice and how strong the evidence is.

## 2. Design

### 2.1 Tiers
These definitions are used both to pick tasks and later to route real work.

| Tier | A change is in this tier when… |
|---|---|
| easy | ≤ ~50 changed lines in 1–2 files; the fix location follows from a symptom; no new interface. |
| medium | ≤ ~300 lines in one subsystem; it changes a contract inside the repo (script interface, exit codes, harness) and needs new tests; or it's a review fix round. |
| hard | Go in juju/juju; or cross-layer (API, apiserver and CLI); or security-sensitive CI; or real design choices; or > 300 lines. |

### 2.2 Tasks (details in [TASKS.md](TASKS.md))

| Task | Tier | What | Status |
|---|---|---|---|
| E1 | easy | blondie-lab: suite temp files unreadable by snap juju | verified |
| E2 | easy | blondie-lab: confirmation prompts abort suites | verified |
| E3 | easy | blondie-lab: local test charms missing from checkout | verified |
| M1 | medium | blondie-lab #6: other users' models escape cleanup | verified |
| M2 | medium | blondie-lab #9: teardown failures scored as infra, plus README drift lint | verified, base sanitised |
| M3 | medium | blondie-devenv change | SLOT; fallback is the #8 review fix round (verified) |
| H1 | hard | juju/juju #22773: charm/model type mismatch at deploy (Go, human-reviewed) | verified |
| H2 | hard | blondie-lab PR-1: lint workflow and fixtures | refs verified; brief text is a SLOT |
| H3 | hard | Juju Go change Blondie wrote | SLOT; fallback is blondie-lab PR-2 |

I couldn't read sinanawad/blondie-devenv, and Blondie's Juju PRs aren't upstream. Those are marked SLOTs with selection rules and fallbacks.

### 2.3 Setups
Launch settings are exact. Cursor uses the v1 API: `model: {id, params}`. Effort is a param, not an id suffix. Every Cursor setup also sends `fast=false` when the model lists a `fast` param (step 3).

| Setup | Role | Harness | `model.id` | `model.params` | Tiers |
|---|---|---|---|---|---|
| `grok-cursor` | writer | Cursor cloud agent | `grok-4.7` | `effort=high` | E M H |
| `grok-build` | writer | Grok Build headless on Blondie's box, as user `evalrunner` | Grok 4.7 id from step 6 | `default_reasoning_effort = "high"` | E M H |
| `composer` | writer | Cursor cloud agent | `composer-2.5` | no effort param; `fast=false` if listed | E M H |
| `sonnet` | writer | Cursor cloud agent | `claude-sonnet-5-5` | `effort=high` | E M H |
| `opus` | writer | Cursor cloud agent | `claude-opus-5-5` | `effort=high` | H (M only if adaptive, §2.8) |
| `sol` | writer | Cursor cloud agent | `gpt-5.6-sol` | `effort=high` | H (M only if adaptive) |
| `grok-build-planrev` | writer | Grok Build plans; an Opus agent reviews the plan; Grok implements in the same session | Grok as above; review uses `claude-opus-5-5`, `effort=high` | | H |
| `historic` | writer | Blondie's original first draft (an existing commit; no cost) | | | where TASKS.md lists one |
| `grader-opus` | grader | Cursor cloud agent | `claude-opus-5-5` | `effort=high` | all |
| `grader-grok` | grader | Grok Build, as `evalrunner` | Grok 4.7 | high | all |
| `adjudicator-sol` | adjudicator | Cursor cloud agent | `gpt-5.6-sol` | `effort=high` | disputed findings only |
| `reviewer-sonnet` | in-loop reviewer candidate | Cursor cloud agent | `claude-sonnet-5-5` | `effort=high` | M H |
| `reviewer-composer` | in-loop reviewer candidate (priority 4) | Cursor cloud agent | `composer-2.5` | no effort param; `fast=false` if listed | M H |

Grok Build headless invocation (full runner in Appendix S5):

```
grok --no-auto-update -p "<prompt>" -m <GROK_MODEL> --cwd <repo> --always-approve --deny WebSearch --deny WebFetch --session-id <run_id> --output-format streaming-json
```

The plan phase of `grok-build-planrev` also passes `--deny Edit` and uses `--output-format plain`. Env for every Grok run: `GROK_MEMORY=0 GROK_WEB_FETCH=0 GROK_SUBAGENTS=0 GROK_DISABLE_AUTOUPDATER=1`.

### 2.4 Run matrix

| Tier (tasks) | Writer setups | New writer runs | Cursor-billed runs |
|---|---|---|---|
| easy (E1–E3) | grok-cursor, grok-build, composer, sonnet (+ historic) | 12 | 9 |
| medium (M1–M3) | the same 4 (+ historic) | 12 | 9 |
| hard (H1–H3) | the same 4 + opus, sol, grok-build-planrev (+ historic) | 21 | 15 writers + 3 plan reviews |

On top of the writer runs:
- **Grading:** 12 batches. Easy and medium get one batch per task; hard gets two batches of ≤ 4 candidates per task. Each batch gets `grader-opus` phase 1 and phase 2, and `grader-grok` phase 1 and phase 2. There is also at most one `adjudicator-sol` run per task.
- **Reviewer experiment:** 9 `reviewer-sonnet` runs (the medium and hard batches).
- **Stage 2:** at most 6 confirmation replicates.

### 2.5 Fairness and isolation
1. **Identical prompt.** Every writer gets Part A + Part B of the brief template and nothing else. The brief is frozen by sha256 before the task's first run. Only the time cap differs, and it's set by tier: easy 45 min, medium 75, hard 120.
2. **Sandbox per task.** Each task gets a private repo `sinanawad/sbx-NN` whose `main` is **one orphan commit** of the base tree. There's no history, so neither the future nor the base's own commit messages are visible. Raw writer branches never coexist: writers for a task run **one at a time**, and Blondie copies each finished branch to its private mirror and deletes it from the sandbox before the next writer of that task starts.
3. **No leaks from the base or the brief.** Base trees are grepped for solution phrases (TASKS.md lists them per task). The M2 base needs sanitising, because its sidecar notes describe the fix. Each brief passes a Grok Build leak check before it's frozen.
4. **No outside sources.** Writers are told not to browse, read other repos or fetch other remotes. Grok Build runs with web tools denied. Cursor runs have their event stream saved, and Blondie greps it for `blondie-lab`, `juju/juju/pull`, `22773`, `sbx-`, `git fetch`/`remote add` against other remotes, and `api.github.com`. A hit flags the run as `contaminated`: it's excluded and re-run once.
5. **Grok Build runs as a separate user (`evalrunner`).** That user can't read Blondie's home, notes, checkouts or `$EVAL`; otherwise `--always-approve` could read the accepted answers and Blondie's credentials. Grok's Cursor/Claude compat scanners are off, memory is off, and **only one Grok process runs at a time**. Every Grok job wipes its work dir and its own files in Grok's session store (`~/.grok`) after its last phase (S5), so a later writer can't read earlier writers' sessions, grading prompts, K-lists or leak checks. Only `grok-build-planrev` keeps a session across phases, and between them it holds only that run's own plan. Grok grader phase 2 starts a fresh session (REVIEWER_PROMPT §2).
6. **Blondie makes no judgements.** Blondie wrote most of these changes and has seen their reviews. It only runs mechanical steps. Every severity, match or verdict comes from a fresh agent or from Sinan.
7. **Same environment per harness.** Cursor setups share the default cloud image. Grok Build gets the box with the Go memory limits in Appendix S5. An out-of-memory kill is recorded as `infra-fail`, not as a quality result.

### 2.6 Grading
1. **Gates (objective, run by Blondie).**
   - blondie-lab: `gate-lab.sh` (harness, shellcheck, actionlint, zizmor, fixture check).
   - Juju: an `eval-gates.yml` Actions workflow in the sandbox (build, unit tests of the touched packages plus the gate list, schema up to date). It's added only after the task's writers finish.
2. **Hidden checks (objective).** Per-task behavioural scripts written by Blondie from TASKS.md. Each must fail on the base and pass on the accepted tree before use. Graders never see the results.
3. **Blind review, two vendors.** `grader-opus` (Anthropic) and `grader-grok` (xAI) each run phase 1 of [REVIEWER_PROMPT.md](REVIEWER_PROMPT.md) on every batch. Candidates are anonymised squashed commits on `cand/<4 hex>` branches, in random order. The graders don't see the accepted change.
4. **Cross-check.** In phase 2, each grader rules on the other grader's blockers and majors (`same`, `agree` or `disagree`) and fills in the task's known-issue checklist.
5. **Finding status.**
   - **Confirmed:** raised by both graders, or raised by one and agreed by the other, or a known issue marked present by both. The final severity is the lower of the two.
   - **Disputed:** one grader says `disagree`, or the graders differ on a known issue. `adjudicator-sol` (OpenAI, which grades nothing else) decides; its verdict becomes final.
   - **Rejected:** the adjudicator says not real.
   - The design checks self-preference both ways. Opus grading the `opus` writer, or Grok grading the Grok setups, can't confirm or clear anything alone.
6. **Sinan's spot-check** (about 30 min). Up to 12 items: every adjudicated dispute (at most 6) and 6 confirmed majors drawn at random across setups. He marks each `real` or `not-real`. If 2 or more of the 6 confirmed majors are `not-real`, the report flags over-strict grading and repeats the ranking using only majors raised by both graders.

### 2.7 Metrics
- **Primary, per candidate:**
  - confirmed blockers and majors;
  - `pr_ready`: gates pass, 0 confirmed blockers and 0 confirmed majors.
- **Secondary:**
  - hidden-check pass rate;
  - confirmed minors;
  - known issues present;
  - Cursor $ (token usage × price table);
  - wall minutes;
  - infra failures;
  - for Grok Build, peak memory and rate-limit hits.
- **Reviewer experiment:** per reviewer and tier, recall and precision against confirmed blockers and majors.
  - recall = confirmed items matched ÷ confirmed items;
  - precision = matched ÷ blockers and majors raised.
  - The graders' own numbers are reported but marked biased, because they helped build the confirmed set.
- **Dropped:** diff closeness to the accepted version. It's used only as a contamination flag: a near-verbatim match gets a manual look.

### 2.8 Decision rule
For tier T and setup S, use only setups with a gradeable candidate on every task of T. An `infra-fail` run is re-run once; if it fails again, S is "not evaluable" on T.
- Definitions:
  - `B` = confirmed blockers;
  - `M` = mean confirmed majors per task;
  - `G` = gates pass on all tasks;
  - `C` = mean Cursor $ per task (writer plus plan review; Grok Build counts as $0 Cursor).
- **Eligible:**
  - easy: `B = 0`, `G`, and at most one confirmed major across the tier;
  - medium: `B = 0`, `G`, `M ≤ 1.0`;
  - hard: `B = 0`, gates pass on all but at most one task, and `M ≤ M_best + 1.0`. `M_best` is the lowest `M` among setups with `B = 0`.
- **Pick** the lowest `C` among eligible setups. If another eligible setup costs within 20% or $0.50 of it and has a lower `M`, pick that one instead. `grok-build` also needs at most one infra or rate-limit failure in the tier.
- **Adaptive (priority 4):** if nothing is eligible on easy or medium, run `opus` and `sol` on that tier and apply the rule again. If nothing is eligible on hard, recommend the setup with the lowest `2B + M`, and keep Opus-level review plus Sinan's review on every hard PR.
- **Confirm (Stage 2):** a picked setup other than `opus` or `sol` gets one replicate per task of the tier. It must be eligible on the replicates alone; otherwise it's reported as "not confirmed" and the runner-up is tried if budget allows.
- **Plan review:** adopt "Grok + Opus plan review" for hard work if `grok-build-planrev` is eligible on hard and `grok-build` isn't.
- **Harness:** where a Grok writer is picked, prefer `grok-build` over `grok-cursor` if `M(grok-build) ≤ M(grok-cursor) + 0.5` and grok-build has no blocker that grok-cursor lacks.
- **Reviewer:** per tier, pick the cheapest reviewer with recall ≥ 0.8 and precision ≥ 0.6. If none qualifies, keep Opus.
- **Evidence strength:** "moderate" if the pick is confirmed by its replicate and leads the next setup by ≥ 1 major per task; otherwise "weak".

### 2.9 Budget and stop rules
- **Cap: $200 of Cursor spend for the whole eval**, priced from token usage. It covers writers, plan reviews, graders, the adjudicator, reviewer runs, and Blondie's own orchestration if that's billed. Sinan also sets Cursor's on-demand spend limit so the cap holds even if Blondie fails (A3).
- **Why $200:** at 80% of Ultra in two days, this is roughly one day of the current burn. A tier rule that moves routine work off Opus should repay it within the week.
- **Sizing:** the matrix keeps priority 1 at roughly $120–150, *assuming* a strong-model run averages ≤ $10 and a cheap one ≤ $2. Wave 1 replaces these assumptions with measured numbers.
- **Priorities:**
  - P1: writer runs and grading (both graders and adjudication) for every task.
  - P2: `reviewer-sonnet`.
  - P3: Stage 2 replicates for easy and medium.
  - P4: adaptive `opus`/`sol` on medium, and `reviewer-composer`.
- **Per-run caps:**
  - Wall time: writers easy 45 min, medium 75, hard 120; graders 90; follow-ups 45; plan review 30.
  - Cursor $: writers easy $4, medium $8, hard $20; grader batch $15; any other run $5.
  - At a cap, the poller cancels the run and records `timeout` or `cost-cap`. The candidate is graded with whatever it pushed.
  - At Checkpoint A each $ cap is reset to the larger of the default and 3× the measured median for that model and tier.
- **Checkpoint A** (after Wave 1 is graded): projection = spent + the remaining planned runs × the measured mean $ per model and tier. Hard runs use 2× the medium mean until they're measured. If the projection is over $180, apply these cuts in order until it isn't:
  1. drop `reviewer-composer`;
  2. drop adaptive medium runs;
  3. drop `sonnet` writer on easy;
  4. drop H3;
  5. drop medium replicates;
  6. drop `sol` on H2;
  7. drop `reviewer-sonnet` on hard;
  8. stop after Wave 2 and report.
- **Soft stop at $160:** no new writer or replicate launches; finish grading of tasks whose writers are done, then report.
- **Hard stop at $200:** cancel every active Cursor run, then write a partial report.
- **Grok Build:** after 3 rate-limit errors in a row, pause it for 30 minutes. If they continue, mark the remaining `grok-build` runs `quota` and carry on with everything else.

### 2.10 What this can't tell us
- With 3 tasks per tier and mostly one run each, only large gaps (≥ ~1 major per task) are real.
- Six tasks come from a single repo written by one agent. Only H1 (and H3, if it's filled) is Go.
- Models may have seen juju/juju #22773 in training; it merged in July 2026.
- `grok-build` runs on a 2.5 GB box, so Go builds may be killed; the report keeps this apart from model quality.
- The rule is re-checked monthly (§6).

## 3. Changes from the draft and why
1. **The grader no longer grades itself alone.** The draft had Opus at max effort grade everything, Opus outputs included, with GPT-5.6 Sol as a second opinion. Now two graders from two vendors (Opus and Grok, at high effort) cross-check each other. Sol, a third vendor that writes but doesn't grade, settles disputes. A finding counts only when it's confirmed.
2. **Blind and leak-proof by construction.** The draft had nothing that stopped writers from seeing the answer. Now there's a private orphan-commit sandbox per task, writers for a task run one at a time with branches removed, base trees are sanitised, briefs are leak-checked, transcripts are grepped, and Grok runs under a separate user. Blondie, which wrote most of these changes, does no judging and doesn't write the requirements free-hand.
3. **"Blondie as today (Auto)" is replaced by the historic first drafts.** Auto isn't a setup anyone can pick on purpose, and re-running it costs money. Blondie's real first drafts are the true baseline, and they're free.
4. **Writer and reviewer are measured separately.** The draft's "Composer + Sonnet self-review" mixed two variables. Composer and Sonnet are now separate writers, and the reviewer question is a separate measurement on the same candidates. That matters because Opus reviewing every PR is likely a large part of the spend (step 2 checks).
5. **The decision rule uses absolute and relative bars.** "Close to E" depended on running Opus on everything and has no threshold. Now there are per-tier eligibility bars, a cheapest-eligible pick, a confirmation replicate, and an evidence-strength label. Opus and Sol run on easy and medium only if nothing cheap passes.
6. **Objective signals come first.** Gates and hidden behavioural checks were added, plus known-issue checklists from real reviews (H1's are from Juju maintainers). "Rework rounds" was dropped as too costly to measure, and "diff closeness" is now a contamination flag only.
7. **Costs are capped.** A $200 cap with per-run caps, a calibration checkpoint, a fixed cut order, soft and hard stops, and a Cursor spend limit as a backstop. Batched grading replaced the draft's two max-effort reviews of every output.
8. **Smaller items:**
   - Sonnet 5.5 was added as a writer.
   - G's writer is Grok Build, so the only Cursor cost is the plan review.
   - The local-vs-cloud Cursor CLI check was cut. It's an infra question, and Grok Build's runs on the box already report memory and out-of-memory kills.
   - The "top 3 run twice on hard" rule was replaced by replicates where a decision depends on them.
   - Every task is concrete, with refs.

## 4. Runbook

Conventions:
- `EVAL=/workspace/model-eval` (mode 700, owned by Blondie).
- Run id `<task>-<setup>-r<n>`, for example `M1-sonnet-r1`.
- Every step lists its maximum duration. Anything that may run longer than 10 minutes is started detached (`setsid nohup … > $EVAL/logs/<name>.log 2>&1 &`) and checked in a later step or TICK, so **no step ever takes more than 50 minutes**.
- Status line: define this once and call it as the steps say:
  `st() { /workspace/bin/botstatus blondie "model-eval: $*"; }`
  If `botstatus --help` shows a different call form, change only the body of `st`. Message format: `<phase> | <detail> | $<spent>/$200`.

### Part A: prerequisites (Friday night; Blondie checks them at step 1)
- **A1 (Sinan).** Create nine private repos with Actions disabled:

  ```bash
  for n in 01 02 03 04 05 06 07 08 09; do gh repo create sinanawad/sbx-$n --private && gh api -X PUT repos/sinanawad/sbx-$n/actions/permissions -F enabled=false; done
  ```

  The mapping is in TASKS.md. Neutral names stop writers from learning the tier.
- **A2 (Sinan).** Add `sbx-01`…`sbx-09` to the Blondie GitHub App installation (contents: write; actions: write and administration: write for `sbx-07`/`sbx-09`, to run the gate workflow) and to Cursor's GitHub App installation.
- **A3 (Sinan).** In the Cursor dashboard, set the on-demand spending limit so total spend from now can't pass the current spend + $200 (or whatever cap Sinan approves).
- **A4 (Blondie if it has sudo, else Sinan).**
  - Create user `evalrunner`: no sudo, home mode 700, no read access to Blondie's home.
  - Log Grok Build in as that user (SuperGrok). `grok login` may need Sinan for the browser step.
  - Create `/home/evalrunner/{work,in,bin}`.
- **A5 (Sinan).** Answer the open questions in the PR: the cap; the M3 and H3 slots; JUJU-10101's text; where the report goes.

### Part B: preflight (Saturday morning)
1. **(≤ 10 min) Check prerequisites.**
   - Run `/workspace/bin/botstatus --help` and define `st`.
   - Check that A1–A4 are done: `gh api repos/sinanawad/sbx-0N`, `id evalrunner`, and `sudo -u evalrunner -H grok --no-auto-update -p "Reply OK" --output-format plain` prints OK.
   - If anything is missing, `st "blocked | prerequisite <X> missing"`, ask Sinan, and continue with what doesn't depend on it. Grok setups wait for A4; everything waits for A1 and A2.
   - Then `st "preflight | started"`.
2. **(≤ 15 min) Baseline usage.**
   - Write `$EVAL/baseline.md`: Cursor usage % and $ (dashboard), the per-model split for the last 7 days if it's visible, and the reset date.
   - This shows how much of the 80% came from Opus reviews versus writing; it goes in the report.
3. **(≤ 10 min) Check model ids.**
   - Run `curl -sS -u "$CURSOR_API_KEY:" https://api.cursor.com/v1/models > $EVAL/models.json`.
   - For each Cursor id in §2.3, confirm the id and its `effort`/`fast` params and values, and write `$EVAL/setups.csv` (`setup_id,role,harness,model_id,params_json`). For example: `opus,writer,cursor,claude-opus-5-5,[{"id":"effort","value":"high"},{"id":"fast","value":"false"}]`.
   - If a listed id differs (say `claude-opus-5.5`), use the listed one. If a model has no `fast` param, leave it out.
   - If an id isn't listed, still try it in step 17. If that launch returns 400, `st "blocked | model <id> unavailable"` and drop that setup.
4. **(≤ 15 min) Prices.**
   - Write `$EVAL/prices.csv` with columns `model_id,input_per_m,output_per_m,cache_write_per_m,cache_read_per_m,source,date`, one row per Cursor model id. The source is Cursor's model pricing docs page; if a price is missing there, use the provider's public API price and say so in `source`.
5. **(≤ 30 min) Tools on the box.**
   - `jq`, `shellcheck`, `openssl`, `/usr/bin/time`, git ≥ 2.40.
   - actionlint 1.7.12: the release tarball, sha256 `8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8`.
   - zizmor 1.30.1 in a venv from this repo's `lint-requirements.txt` (`pip --require-hashes --only-binary :all:`).
   - Write the scripts in Appendix S to `$EVAL/tools/` and `/home/evalrunner/bin/`.
6. **(≤ 15 min) Grok Build config.**
   - As `evalrunner`, run `grok --help` and list the models: `/model` in the TUI, or the catalogue the help points to. Pick the Grok 4.7 id and record it as `GROK_MODEL` in `setups.csv`.
   - If Grok 4.7 isn't offered, use the default model, record it, and note in the report that `grok-build` and `grok-cursor` then differ in model too.
   - Write the `~/.grok/config.toml` from Appendix S6.
   - Run S5 once with a "Reply OK" prompt and `mode=plan` in an empty `git init` dir. Check that `new-files.txt` lists the session files it created under `~/.grok` and no login or credential file (if it does, extend `GROK_KEEP` in S5), and that `wipe` removes them while `grok` still works afterwards. If Grok keeps all sessions in one shared file, the wipe deletes that file; then a planrev's implement phase must start before any other Grok job.
   - Record `grok --version`.
7. **(≤ 5 min)** Create `runs.csv`, `results.csv` and `findings.csv` with the headers in §5. Then `st "preflight | done"`.

### Part C: prepare tasks
8. **(≤ 20 min) Sources.**
   - In a blondie-lab clone: `git fetch origin 'refs/pull/*/head:refs/remotes/origin/pr/*'`.
   - For H1: `git init $EVAL/src/juju && git -C $EVAL/src/juju fetch --depth 1 https://github.com/juju/juju f498ee4eec4851d23232d39dc0b62996d8980cfa` (run it detached; check it in step 9).
   - Fill the SLOTs (M3, H2's brief, H3) by the rules in TASKS.md, or choose the fallbacks. Write `$EVAL/tasks.csv` (`task_id,tier,sandbox,source_repo,source_base,accepted_ref,historic_ref,sandbox_base_sha,brief_sha256,leak_check,status`).
9. **(≤ 15 min per task; juju detached) Build the sandboxes.** For each task:
   1. Export the base tree into a temp dir (`git archive <source_base> | tar -x`).
   2. Sanitise it: M2's sentence edit; for H1 and H3, delete `.github/workflows/`.
   3. Run `git init -b main`, add everything, and commit as `eval <eval@invalid>` with date `2026-01-01T00:00:00Z` and message `base`.
   4. Push to `sinanawad/sbx-NN` `main`.
   5. Clone a bare mirror to `$EVAL/mirror/<task>.git`.
   6. Record `sandbox_base_sha`.
10. **(≤ 15 min) Leak scan the bases.**
    - Run `git -C $EVAL/mirror/<task>.git grep -nE '<phrases from TASKS.md>' main` for each task. Any hit means sanitise the base and rebuild (step 9).
    - For M2, also run `bash scripts/gen-suite-readme.sh --check sidecar-k8s` on the base (it must exit 0).
11. **(≤ 45 min) Write the briefs.**
    - Use [TASK_BRIEF_TEMPLATE.md](TASK_BRIEF_TEMPLATE.md) (Part A + Part B, `{{CAP_MIN}}` by tier) and the drafts and sources in TASKS.md, into `$EVAL/briefs/<task>.md`.
    - Follow Part D's rules. Don't add requirements beyond TASKS.md.
12. **(≤ 30 min) Leak-check each brief** with the Part D prompt (Grok Build, one task at a time, `S5 mode=plan` in an empty `git init` dir so it can't see any repo).
    - Remove flagged sentences (quoted origin text excepted) and check again.
    - Freeze: `sha256sum` into `tasks.csv`, then `chmod 444`. `st "prep | briefs frozen"`.
13. **(≤ 45 min) Hidden checks.**
    - Write `$EVAL/hidden/<task>.sh <worktree>`. It prints `passed/total` and exits 0.
    - Each check must FAIL on the sandbox base and PASS on the accepted tree. Record both results in `tasks.csv` `status`.
    - A check that can't meet both is dropped (and noted).
14. **(≤ 15 min) Historic candidates.** For each task with a historic ref:
    1. Apply `git diff <historic>^ <historic>` onto a worktree of the mirror's `main`. For M3 or other multi-commit drafts, use `<first>^..<last>`.
    2. Commit it to `refs/raw/<task>-historic-r1`.
    3. Add a `runs.csv` row with `status=ok`, `cost_usd=0`.
15. **(≤ 10 min)** Fill in the gate workflow from Appendix S4 for `sbx-07` and `sbx-09`. Don't push it yet. Then `st "prep | done; 9 tasks, N runs queued"`.

### Part D: writing (waves and the TICK loop)
16. **(≤ 10 min) Write `$EVAL/queue.csv`** (`run_id,task,setup,wave,state`). The order within a task: `composer`, `grok-cursor`, `sonnet`, `opus`, `sol`. Grok Build has one global queue: each wave's tasks in order, with `grok-build-planrev` right after its task's `grok-build`.
    - Wave 1: E1, E2, E3, M1.
    - Wave 2: M2, M3, H2. It starts when Wave 1's writers are done.
    - Wave 3: H1, H3. It starts after Checkpoint A.
17. **(≤ 50 min) Smoke test.**
    - Launch `E3-composer-r1` (S1; it starts its poller, S2), and run TICKs until it's done.
    - Then run harvest, anonymise and gate on it (S3, S4), without publishing.
    - If any part fails, fix the tool and repeat. A clean smoke run counts as the real run.
    - `st "wave1 | smoke ok"`.
18. **TICK** (repeat every 10–20 min; each TICK takes ≤ 15 min and is idempotent):
    1. **Budget:** spent = sum of `runs.csv.cost_usd` plus live estimates (`cost.sh`) for active runs. Apply §2.9 (soft or hard stop, or the Checkpoint A cuts once they're set).
    2. **Finished Cursor writers** (`$EVAL/logs/<run>.status` exists):
       - Fill the `runs.csv` row: tokens and `cost_usd` from `cost.sh <agent> <model> <cursor_run>`, plus status and wall time.
       - Grep `<run>.sse` for the leak patterns in §2.5 (item 4), fill `leak_hits`, and mark the run `contaminated` if there's a hit.
       - Harvest it (S3).
       - Status `ERROR` or `EXPIRED` with no branch means `infra-fail`: re-queue it once.
    3. **Finished Grok phases** (a new `/home/evalrunner/work/<run>/exit-<mode>`):
       - Writer `write` or `impl`: harvest it (S3). Writer `plan`: go to item 7. Grader `p1`/`p2`: go to Part E step 22 or 23.
       - Read peak memory from `time-*.txt` ("Maximum resident set size").
       - Exit 137, or "Killed" in stderr, means `oom=y` and `infra-fail`: re-queue it once.
       - Count `rate limit` or `429` in stderr.
       - After the job's last phase (anything except a planrev `plan`), and after harvesting or reading its JSON, run `sudo -u evalrunner -H ~evalrunner/bin/run-grok.sh <run_id> 0 - wipe`. It deletes the work dir and the session files the job created. The next Grok job must not start before the wipe.
    4. **Stray branches:** after any Cursor grader, reviewer or plan-review run ends, delete every sandbox branch except `main` and `cand/*` (`git ls-remote --heads` then `git push --delete`), so later graders can't see another run's output.
    5. **Juju gates (H1, H3):** `gh run list -R sinanawad/sbx-0N -w eval-gates.yml --json databaseId,status,conclusion,displayTitle`; for each completed run, copy the build, test and lint conclusions into that candidate's `results.csv` `gate_*` columns.
    6. **Launch Cursor runs:** for each task with no active writer, launch the next queued writer, provided fewer than 6 Cursor agents are active and the budget allows (S1).
    7. **`grok-build-planrev` hand-offs:**
       - When its plan phase has ended, launch the Opus plan review (REVIEWER_PROMPT §4, cap 30 min) on that task's sandbox.
       - When the review finishes, start Grok's implement phase with C2 in the same session (S5 `mode=impl`, same run id).
    8. **Grok queue:** if no Grok process is running, start the next job (S5).
    9. **Grading:** when every writer of a task is done, run Part E steps 20–24 for it.
    10. **Status:** if anything changed, `st "<wave> | running: <ids> | done: <n>/<total>"`.
19. **(≤ 30 min) Checkpoint A** (when Wave 1 grading is complete):
    - Compute the measured mean $ and wall time per model and tier, the projection and the new per-run caps.
    - Apply the cuts.
    - Write `$EVAL/checkpoint-a.md`.
    - `st "checkpoint A | projected $X | cuts: <list>"`.
    - Then release Wave 3.

### Part E: grading (per task, as soon as all its writers are done)
20. **(≤ 30 min) Prepare candidates.**
    1. Anonymise every non-contaminated raw ref (S3, `anon.sh`). Look over the vendor-name grep it prints: redact attributions in comments and docs as `[redacted]`, never code, and note it.
    2. Gates: for blondie-lab tasks run `gate-lab.sh` on each candidate (S4; detached if there are more than 4 candidates). For H1 and H3, push `eval-gates.yml` to the sandbox's `main`, enable Actions, and dispatch it once per candidate.
    3. Run `hidden/<task>.sh` on each candidate.
    4. Push `cand/*` to the sandbox.
    5. Fill `results.csv` with gates, hidden checks and costs.
21. **(≤ 15 min) Phase 1.**
    1. Make batches: one per easy or medium task, two of ≤ 4 candidates per hard task, with random assignment and order.
    2. For each batch, launch `grader-opus` (Cursor, on the sandbox, REVIEWER_PROMPT §1 with the Cursor `OUTPUT_RULE`).
    3. Queue `grader-grok` (Grok queue, a clone bundled with **only** `main` and `cand/*`, with the Grok `OUTPUT_RULE`).
    4. If within budget priority, launch `reviewer-sonnet` with the identical §1 text on medium and hard batches (P2), and `reviewer-composer` (P4).
22. **(≤ 15 min, when both graders' phase 1 is in) Phase 2.**
    - For Opus, send the §2 follow-up through `POST /v1/agents/{id}/runs`. For Grok, queue a new S5 job `<batch>-grok-p2` with `mode=p2` and the fresh-session prompt from REVIEWER_PROMPT §2 (phase 1 was `<batch>-grok-p1`, `mode=p1`).
    - Each grader gets the other grader's blockers and majors and the task's K-list.
23. **(≤ 20 min) Resolve findings.**
    1. Load both graders' JSON into `findings.csv`. Opus's JSON is the `result` field of its `logs/<run>.run.json`; Grok's are `/home/evalrunner/work/<batch>-grok-p1/<batch>-p1.json` and `/home/evalrunner/work/<batch>-grok-p2/<batch>-p2.json` (the parent of each job's repo clone). If either isn't valid JSON, send one follow-up asking for the JSON only; if that fails too, mark the batch `infra-fail` for that grader.
    2. Apply the status rules in §2.6. The `same:<id>` answers give the matching. A known issue marked present by both graders becomes a confirmed finding if no confirmed finding already covers it. Use the `same` and `agree` mappings: a known issue whose evidence points to the same file and line as a confirmed finding counts as that finding.
    3. Collect the disputed items, launch one `adjudicator-sol` run per task (§3), and apply its verdicts.
24. **(≤ 15 min) Score.**
    - Fill the `results.csv` columns for confirmed blockers, majors and minors, known issues, `pr_ready` and `disputed_open`.
    - For reviewer runs, queue one Grok matching job (REVIEWER_PROMPT §5; `S5 mode=plan` in an empty `git init` dir, with the inputs pasted into the prompt) per batch and fill `reviewer_recall` and `reviewer_precision` in the report data.
    - `st "graded <task> | pr_ready <k>/<n>"`.

### Part F: confirmation and spot-check
25. **(≤ 15 min) Stage 2.**
    - Apply §2.8 to get the provisional picks.
    - Queue one replicate (`-r2`) per task for each pick that needs confirmation (P3, within budget).
    - Run them through Part D and Part E. Each task's replicates are graded as their own fresh batch (new grader runs, never a follow-up to the r1 batch), so graders don't see the r1 candidates.
26. **(≤ 15 min) Sinan's spot-check.**
    - Write `$EVAL/report/spot-check.md`: up to 12 items, each with the finding, its candidate branch, the evidence, and checkboxes for real or not real.
    - Ask Sinan; `st "waiting | Sinan spot-check"`.
    - Record his answers in `findings.csv.sinan_check`.

### Part G: report
27. **(≤ 45 min)** Write the report (§6) and attach `runs.csv`, `results.csv`, `findings.csv`, `setups.csv`, `tasks.csv`, `checkpoint-a.md` and `baseline.md`.
    - Open a PR in sinanawad/blondie-devenv at `model-eval/2026-10-17/`, unless Sinan chose another place.
    - Archive the agents (`POST /v1/agents/{id}/archive`).
    - Leave the sandboxes private for 30 days, then delete them.
    - `st "done | report <url> | $<spent>/$200"`.

## 5. Data files (CSV, comma-separated, UTF-8, header row)

**`results.csv`** is the results table, with one row per candidate:
`task_id,tier,setup_id,replicate,cand_label,run_status,gate_build,gate_tests,gate_lint,gate_notes,hidden_passed,hidden_total,blockers_confirmed,majors_confirmed,minors_confirmed,nits,known_issues_present,known_issues_total,disputed_open,pr_ready,writer_cost_usd,planreview_cost_usd,writer_tokens_total,wall_min,peak_rss_mb,leak_flag,notes`
- `run_status`: `ok`, `timeout`, `cost-cap`, `infra-fail`, `contaminated`, `no-diff` or `quota`.
- `gate_*`: `pass`, `fail` or `n/a`.
- `pr_ready`: `1` or `0`.

**`runs.csv`** is the cost ledger, with one row per agent run of any role:
`run_id,role,task_id,setup_id,harness,model_id,params,agent_id,cursor_run_id,started_utc,ended_utc,wall_min,status,branch,tokens_input,tokens_output,tokens_cache_write,tokens_cache_read,tokens_total,cost_usd,oom,rate_limit_hits,leak_hits,notes`
- `role`: `writer`, `plan`, `plan-review`, `grader-p1`, `grader-p2`, `adjudicator`, `reviewer-exp`, `matcher`, `leak-check` or `orchestration`.
- `harness`: `cursor`, `grok-build` or `none`.

**`findings.csv`** has one row per finding:
`finding_id,task_id,cand_label,source,severity_raised,category,file,line,summary,failing_scenario,verified,other_grader,matched_to,adjudication,severity_final,status_final,sinan_check`
- `source`: `grader-opus`, `grader-grok`, `reviewer-sonnet`, `reviewer-composer` or `known-issue`.
- `other_grader`: `same`, `agree`, `disagree` or `n/a`.
- `status_final`: `confirmed`, `disputed`, `rejected` or `unreviewed`. `unreviewed` covers minors and nits that were never cross-checked; they count as raised, not confirmed.

How to record cost:
- **Cursor:** `cost.sh` (S2) reads `GET /v1/agents/{id}/usage?runId=…` and multiplies the four token counts by `prices.csv`. Do it at the end of every run, and for active runs at every TICK.
- **Grok Build:** `cost_usd=0`. Record wall time, peak memory and rate-limit hits, plus any usage the JSON output reports, in `notes`.
- **Blondie's own orchestration:** if it's billed to the same account, add one `orchestration` row per Part, using Blondie's own usage readout.

## 6. Final report format (`REPORT.md`, ≤ 2 pages plus tables)
1. **Decision:** the rulebook table.

   | Tier | Writer | Reviewer | Review policy | Mean $/task | Evidence |
   |---|---|---|---|---|---|
   | easy | … | … | … | … | moderate or weak |
   | medium | … | … | … | … | … |
   | hard | … | … | … | … | … |

   Review policy is one of: every PR, plan only, or plan + PR.

   Then 3–5 sentences: what changes from today's workflow, and the expected monthly Cursor saving at the current PR rate.
2. **Per-tier results:** setup, tasks, gates pass, total confirmed blockers, mean majors, mean minors, hidden pass %, `pr_ready` k/n, mean $, mean wall, infra failures, eligible (y/n).
3. **Reviewers:** recall, precision and $ per review, by reviewer and tier. Opus and Grok are marked biased.
4. **Plan review:** `grok-build-planrev` against `grok-build` on hard. **Harness:** `grok-build` against `grok-cursor`.
5. **Grading reliability:**
   - Opus–Grok agreement rate;
   - disputes and their outcomes;
   - Sinan's spot-check precision;
   - the both-raised-only sensitivity ranking, and whether it changes any pick.
6. **Cost:** spent against the cap by priority and role; the Cursor dashboard delta against `baseline.md`; Checkpoint A cuts.
7. **Validity notes:** contaminated or `infra-fail` runs, SLOT fallbacks used, and the limits from §2.10.
8. **Re-run:** monthly, one fresh task per tier from that month's merged work. Run the current pick, the runner-up and one new challenger, with the same protocol. Change a rule only if the gap is ≥ 1 confirmed major per task.

## Appendix S: scripts (Blondie writes them in step 5)

**S1. `launch.sh <run_id> <sandbox> <model_id> <params_json> <prompt_file>`**
```bash
#!/usr/bin/env bash
set -euo pipefail
run=$1 repo=$2 model=$3 params=$4 prompt=$5
body=$(jq -n --rawfile t "$prompt" --arg m "$model" --argjson p "$params" \
  --arg u "https://github.com/sinanawad/$repo" \
  '{prompt:{text:$t}, model:{id:$m, params:$p}, repos:[{url:$u, startingRef:"main"}], autoCreatePR:false}')
resp=$(curl -sS --fail-with-body -u "$CURSOR_API_KEY:" -H 'Content-Type: application/json' \
  -d "$body" https://api.cursor.com/v1/agents)
agent=$(jq -r .agent.id <<<"$resp"); crun=$(jq -r .run.id <<<"$resp")
echo "$run,$agent,$crun,$model,$(date -u +%FT%TZ)" >> "$EVAL/launched.csv"
setsid nohup "$EVAL/tools/poll.sh" "$run" "$agent" "$crun" "$CAP_MIN" "$CAP_USD" "$model" \
  > "$EVAL/logs/$run.poll.log" 2>&1 &
```
Set `CAP_MIN` and `CAP_USD` (the per-run caps from §2.9, or Checkpoint A's revised ones) in the environment before every call; the script fails under `set -u` if they're missing.

Follow-ups (grader phase 2) use the same body shape without `model` and `repos`, sent to `POST /v1/agents/$agent/runs`, followed by `poll.sh` on the new run id.

**S2. `poll.sh` and `cost.sh`**
```bash
#!/usr/bin/env bash
# poll.sh <run_id> <agent_id> <cursor_run_id> <cap_min> <cap_usd> <model_id>
set -uo pipefail
run=$1 agent=$2 crun=$3 capmin=$4 capusd=$5 model=$6
api() { local p=$1; shift; curl -sS -u "$CURSOR_API_KEY:" "$@" "https://api.cursor.com/v1/agents/$agent$p"; }
log="$EVAL/logs/$run"; start=$SECONDS
( while :; do   # transcript for the leak grep; resumes after disconnects
    hdr=(); last=$(grep -oP '^id: \K.*' "$log.sse" 2>/dev/null | tail -1)
    [[ -n $last ]] && hdr=(-H "Last-Event-ID: $last")
    curl -sSN -u "$CURSOR_API_KEY:" "${hdr[@]}" \
      "https://api.cursor.com/v1/agents/$agent/runs/$crun/stream" >> "$log.sse"
    grep -q '^event: result' "$log.sse" && break; sleep 5
  done ) & sse=$!
while :; do
  st=$(api "/runs/$crun" | jq -r .status)
  case $st in FINISHED|ERROR|CANCELLED|EXPIRED) break ;; esac
  if (( (SECONDS - start) / 60 >= capmin )); then api "/runs/$crun/cancel" -X POST; st=timeout; break; fi
  usd=$("$EVAL/tools/cost.sh" "$agent" "$model" "$crun" || echo 0)
  if awk -v a="$usd" -v b="$capusd" 'BEGIN{exit !(a>b)}'; then api "/runs/$crun/cancel" -X POST; st=cost-cap; break; fi
  sleep 60
done
sleep 10; kill "$sse" 2>/dev/null
api "/runs/$crun" > "$log.run.json"; api "/usage?runId=$crun" > "$log.usage.json"
echo "$st" > "$log.status"
```
```bash
#!/usr/bin/env bash
# cost.sh <agent_id> <model_id> [cursor_run_id] -> USD (list-price equivalent)
set -euo pipefail
agent=$1 model=$2 q=${3:+?runId=$3}
u=$(curl -sS -u "$CURSOR_API_KEY:" "https://api.cursor.com/v1/agents/$agent/usage$q" | jq -c .totalUsage)
p=$(awk -F, -v m="$model" '$1==m{print $2","$3","$4","$5}' "$EVAL/prices.csv")
[[ -n $p ]] || { echo "no price for $model" >&2; exit 1; }
jq -rn --argjson u "$u" --arg p "$p" '($p|split(",")|map(tonumber)) as [$i,$o,$w,$r]
  | (($u.inputTokens*$i + $u.outputTokens*$o + $u.cacheWriteTokens*$w + $u.cacheReadTokens*$r)/1e6*100|round/100)'
```

**S3. Harvest and anonymise**
- **Cursor:**
  ```bash
  br=$(jq -r '.git.branches[0].branch // empty' "$EVAL/logs/$run.run.json")
  ```
  If `br` is empty, the status is `no-diff`. Otherwise:
  ```bash
  git -C "$EVAL/mirror/$task.git" fetch origin "refs/heads/$br:refs/raw/$run" && git -C "$EVAL/mirror/$task.git" push origin --delete "$br"
  ```
- **Grok:**
  ```bash
  sudo -u evalrunner -H bash -c "cd ~/work/$run/repo && git add -A && { git diff --cached --quiet || git commit -qm wip; } && git bundle create - HEAD" > "$EVAL/logs/$run.bundle" && git -C "$EVAL/mirror/$task.git" fetch "$EVAL/logs/$run.bundle" "HEAD:refs/raw/$run"
  ```
  The `wip` commit means work was left uncommitted; note it.
- **`anon.sh <task> <run_id>`** prints the label:
```bash
#!/usr/bin/env bash
set -euo pipefail
task=$1 run=$2 m="$EVAL/mirror/$task.git"
label=$(openssl rand -hex 2); while git -C "$m" rev-parse -q --verify "refs/heads/cand/$label" >/dev/null; do label=$(openssl rand -hex 2); done
w=$(mktemp -d); git -C "$m" worktree add -q --detach "$w" main
git -C "$m" diff --binary main "refs/raw/$run" -- . ':!.cursor' ':!.grok' ':!.claude' ':!PLAN.md' | git -C "$w" apply --index
export GIT_AUTHOR_NAME=eval GIT_AUTHOR_EMAIL=eval@invalid GIT_COMMITTER_NAME=eval GIT_COMMITTER_EMAIL=eval@invalid \
  GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z
git -C "$w" commit -qm candidate
git -C "$m" update-ref "refs/heads/cand/$label" "$(git -C "$w" rev-parse HEAD)"
git -C "$m" worktree remove --force "$w"
echo "$task,$run,cand/$label" >> "$EVAL/secret/labels.csv"   # chmod 600; graders never see it
git -C "$m" diff main "cand/$label" | grep -inE 'cursor|claude|anthropic|opus|sonnet|openai|gpt|grok|xai|composer|co-authored-by|generated (by|with)' || true
echo "cand/$label"
```
Only delete `PLAN.md` if the base doesn't have one; none of the current bases do.

Publish with `git -C "$m" push origin 'refs/heads/cand/*:refs/heads/cand/*'`. Grok grading bundles hold **only** `main` and `cand/*`:
```bash
git -C "$m" bundle create "$f" main $(git -C "$m" for-each-ref --format='%(refname)' refs/heads/cand/)
```

**S4. Gates**
- **blondie-lab** (`gate-lab.sh <worktree> <label>`; about 2 min per candidate):
```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$1" || exit 2; L="$EVAL/logs/gate-$2"; t=n/a; l=pass; d=""
[[ -f scripts/test-harness.sh ]] && { t=pass; bash scripts/test-harness.sh > "$L.harness" 2>&1 </dev/null || t=fail; }
mapfile -t f < <(git ls-files -z scripts scenarios 2>/dev/null | xargs -0 -r grep -lE '^#!.*\b(ba|da)?sh\b' | sort)
((${#f[@]})) && { shellcheck -x "${f[@]}" > "$L.shellcheck" 2>&1 || { l=fail; d+="shellcheck "; }; }
[[ -d .github/workflows ]] && { actionlint > "$L.actionlint" 2>&1 || { l=fail; d+="actionlint "; }
  cfg=(); [[ -f zizmor.yml ]] && cfg=(--config zizmor.yml)
  zizmor "${cfg[@]}" --min-severity low .github/workflows > "$L.zizmor" 2>&1 || { l=fail; d+="zizmor "; }; }
[[ -f scripts/check-lint-fixtures.sh ]] && { ACTIONLINT=$(command -v actionlint) ZIZMOR=$(command -v zizmor) \
  bash scripts/check-lint-fixtures.sh > "$L.fixtures" 2>&1 || { l=fail; d+="fixtures "; }; }
echo "build=n/a tests=$t lint=$l${d:+ ($d)}"
```
Run zizmor with `GH_TOKEN` set (online audits, as in lint).

- **Juju** (`.github/workflows/eval-gates.yml` in `sbx-07`/`sbx-09`, pushed only after the task's writers finish):
```yaml
name: eval-gates
on:
  workflow_dispatch:
    inputs:
      ref: {description: candidate branch, required: true}
      packages: {description: space-separated package patterns, required: true}
permissions: {}
jobs:
  gates:
    runs-on: ubuntu-24.04
    timeout-minutes: 60
    permissions: {contents: read}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with: {ref: "${{ inputs.ref }}", persist-credentials: false}
      - uses: actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e # v7.0.0
        with: {go-version-file: go.mod, cache: false}
      - name: build
        timeout-minutes: 25
        run: make go-install
      - name: unit tests
        timeout-minutes: 25
        env: {PKGS: "${{ inputs.packages }}"}
        run: make run-go-tests TEST_PACKAGES="$PKGS"
      - name: schema up to date
        timeout-minutes: 10
        run: make rebuild-schema && git diff --exit-code -- apiserver/facades/schema.json
```
Dispatch it with:
```bash
gh api -X POST repos/sinanawad/sbx-07/actions/workflows/eval-gates.yml/dispatches -f ref=main -f "inputs[ref]=cand/<label>" -f "inputs[packages]=<pkgs>"
```
`<pkgs>` is the task's gate list plus the candidate's touched packages:
```bash
git diff --name-only main...cand/<label> -- '*.go' | xargs -r -n1 dirname | sort -u | sed 's|^|./|'
```
Map the step outcomes to `gate_build`, `gate_tests` and `gate_lint` (schema).

**S5. `/home/evalrunner/bin/run-grok.sh <run_id> <cap_min> <prompt_file> [write|plan|impl|p1|p2]`**

`plan` is read-only; `wipe` cleans up after the job's last phase (step 18, item 3); every other mode can edit and only names the output files (`exit-<mode>`, `time-<mode>.txt`). Writers use `write` (or `plan` then `impl` for `grok-build-planrev`); Grok grader jobs use `p1` or `p2`; leak checks and matching use `plan`.

Blondie starts it with `sudo -u evalrunner -H setsid nohup ~evalrunner/bin/run-grok.sh … &`. Before that, it copies the task bundle (`main` only, for writers) to `~evalrunner/in/`, then runs `git clone` into `~/work/<run>/repo`, `git remote remove origin` and `git checkout -b work`.
```bash
#!/usr/bin/env bash
set -u
run=$1 cap=$2 prompt=$3 mode=${4:-write}
W=$HOME/work/$run
if [[ $mode == wipe ]]; then
  [[ -f $W/new-files.txt ]] && xargs -r -d '\n' rm -f -- < "$W/new-files.txt"
  rm -rf -- "$W"; exit 0
fi
cd "$W/repo" || exit 2
touch "$W/start-$mode"
GROK_MODEL=REPLACE_IN_STEP_6
GROK_KEEP=(! -path '*auth*' ! -path '*credential*')   # adjust in step 6
export GROK_MEMORY=0 GROK_WEB_FETCH=0 GROK_SUBAGENTS=0 GROK_DISABLE_AUTOUPDATER=1
export GOFLAGS=-p=1 GOMAXPROCS=2 GOMEMLIMIT=1GiB   # box has ~2.5 GB; a Go build was OOM-killed there
args=(--no-auto-update -p "$(cat "$prompt")" -m "$GROK_MODEL" --cwd "$W/repo" --always-approve
      --deny WebSearch --deny WebFetch --session-id "$run")
if [[ $mode == plan ]]; then
  GROK_WRITE_FILE=0 timeout -k 60 "${cap}m" /usr/bin/time -v -o "$W/time-plan.txt" \
    grok "${args[@]}" --deny Edit --output-format plain > "$W/plan.md" 2>> "$W/grok.stderr"
  rc=$?; git status --porcelain > "$W/plan-dirty.txt"
else
  timeout -k 60 "${cap}m" /usr/bin/time -v -o "$W/time-$mode.txt" \
    grok "${args[@]}" --output-format streaming-json >> "$W/grok.jsonl" 2>> "$W/grok.stderr"
  rc=$?
fi
find "$HOME/.grok" -type f -newer "$W/start-$mode" ! -name config.toml "${GROK_KEEP[@]}" >> "$W/new-files.txt"
echo "$rc" > "$W/exit-$mode"
```
- `GROK_KEEP` holds `find` exclusions for Grok's login and credential files. Set it in step 6 so the wipe never logs `evalrunner` out.
- If `plan-dirty.txt` isn't empty, reset the tree (`git checkout -- . && git clean -fd`) and note it.
- The planrev implement phase calls it again with the same `<run_id>` and `mode=impl`; `--session-id` creates or resumes the named session.
- Every Grok grader phase is its own job (`<batch>-grok-p1`, `<batch>-grok-p2`), with its own clone of the bundle that holds only `main` and `cand/*`.

**S6. `~evalrunner/.grok/config.toml`**
```toml
[models]
default = "REPLACE_IN_STEP_6"
default_reasoning_effort = "high"

[cli]
auto_update = false

[memory]
enabled = false

[subagents]
enabled = false

[compat.cursor]
skills = false
rules = false
agents = false
mcps = false
hooks = false

[compat.claude]
skills = false
rules = false
agents = false
mcps = false
hooks = false
```
