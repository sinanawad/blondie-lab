# Model eval: task catalogue

Companion to [PLAN.md](PLAN.md). Each task is a past change with a known start (base) and a known accepted end. **Base** is the tree writers start from. **Accepted** is the reference for hidden checks and known issues; graders never see it. **Historic** is Blondie's own first draft, which enters the blind pool for free as the `historic` setup.

Stack commits (`be43672`, `c2eea18`, `e04a0d4`, `3557065`, `7d3db74`, `f146fcc`, `b46952a`, `51e26c9`) aren't on `main`. Fetch them with `git fetch origin 'refs/pull/*/head:refs/remotes/origin/pr/*'`.

Status key: **verified** means the refs and texts were checked against GitHub when this plan was written. **SLOT** means Blondie fills it in, following the rules given in that entry.

| Task | Tier | Sandbox | Repo | Status |
|---|---|---|---|---|
| E1 | easy | `sbx-01` | blondie-lab | verified |
| E2 | easy | `sbx-02` | blondie-lab | verified |
| E3 | easy | `sbx-03` | blondie-lab | verified |
| M1 | medium | `sbx-04` | blondie-lab | verified |
| M2 | medium | `sbx-05` | blondie-lab | verified (base must be sanitised) |
| M3 | medium | `sbx-06` | blondie-devenv | SLOT (verified fallback below) |
| H1 | hard | `sbx-07` | juju/juju (Go) | verified |
| H2 | hard | `sbx-08` | blondie-lab | refs verified; brief text is a SLOT |
| H3 | hard | `sbx-09` | juju (Go) | SLOT (fallback below, brief text is a SLOT) |

Severity labels on known issues follow the rubric in [REVIEWER_PROMPT.md](REVIEWER_PROMPT.md). They can differ from the label the original reviewer used.

---

## E1: suite temp files unreadable by juju (`sbx-01`)
- **Base:** `be4367254d5d2ad7d27d9bd286bcb38e3cddf717`. **Accepted:** `35570659b6b367d09e9c3f30626507e5addfddb9`. **Historic:** `3557065` (Blondie's draft was accepted with a test-comment nit).
- **Origin:** failing run 38913122246.
- **Brief (draft):**
  - Context: the blondie-lab harness runs juju/juju's `tests/main.sh` through `scripts/suite.sh`. In snap mode juju comes from the snap (see README).
  - Problem: a suite-backed scenario running juju/juju's `cli` suite on `4.0/stable` fails in `juju model-config --file /tmp/tmp.XXXXXX` with `ERROR open /tmp/tmp.XXXXXX: no such file or directory`. The file exists on the runner when juju is called.
  - R1: suites that hand `mktemp` files to juju work in snap mode.
  - R2: no edits to the juju/juju test tree (it is checked out fresh in each run).
  - R3: an offline case in `scripts/test-harness.sh`.
  - R4: `scripts/test-harness.sh` and shellcheck pass.
- **Base leak scan:** `TMPDIR`, `lab-tmp`, `private /tmp` (expect 0 hits).
- **Known issues:**
  - K1 major: the temp location seen by `main.sh` is still under `/tmp` or `/var/tmp`, or elsewhere the strictly confined snap can't read.
  - K2 major: it's under a hidden directory in `$HOME` (the snap `home` interface doesn't expose dot-dirs).
  - K3 minor: it isn't created fresh per run, or it sits inside `LAB_ARTIFACT_DIR`, which gets uploaded.
  - K4 minor: no harness case, or the case only asserts a variable's value.
- **Hidden checks:** run the candidate's `suite.sh` with the harness's fake `main.sh`, changed to record `mktemp`'s path and test that the file exists.
  - H1: the path isn't under `/tmp` or `/var/tmp`.
  - H2: no component of the path starts with `.`.
  - H3: the file exists while `main.sh` runs.

## E2: confirmation prompts abort suite commands (`sbx-02`)
- **Base:** `c2eea180f7417886d0f23f001f1b082d75932ea0`. **Accepted:** `e04a0d414a8edb12bab5c4bd6e5a85f7b4c53c46`, plus `bootstrap_args` in `b46952a` and a README line in `51e26c9`. **Historic:** `e04a0d4`.
- **Origin:** failing run 38908005678.
- **Brief (draft):**
  - Problem: the `relations` suite on `4.0/stable` fails with `Continue [y/N]? ERROR unit removal: aborted`.
  - R1: suites run non-interactively, without juju confirmation prompts aborting commands. This holds in snap and build mode, on LXD and on MicroK8s.
  - R2: no edits to the juju/juju test tree.
  - R3: an offline harness case.
  - R4: harness and shellcheck pass.
- **Base leak scan:** `model-default mode`, `requires-prompts` (expect 0 hits).
- **Known issues:**
  - K1 major: prompts are off for only some bootstrap paths (snap or build mode, LXD or k8s).
  - K2 major: the fix pipes `yes` or stdin into `main.sh`, or edits upstream tests.
  - K3 minor: the setting isn't visible in the run record (verdict or logs).
  - K4 minor: there's no harness case.
- **Hidden checks:** use the fake `juju` from `test-harness.sh`, which records its arguments, on four paths: LXD and k8s, each in snap and build mode.
  - On each path, the controller's model-default `mode` ends up empty: through `--model-default mode=` at bootstrap, or through a later `juju model-defaults mode=`.

## E3: suites can't find local test charms (`sbx-03`)
- **Base:** `7d3db74c74cdd6478307a732fede6b9698d85653`. **Accepted and historic:** `c2eea180f7417886d0f23f001f1b082d75932ea0`.
- **Origin:** failing run 38906326796.
- **Brief (draft):**
  - Problem: the `relations` suite on `4.0/stable` fails with `Project directory missing: …/juju-tests/testcharms/charms/departer`.
  - R1: suites that pack local test charms work in snap mode.
  - R2: build mode is unchanged.
  - R3: actionlint, harness and shellcheck pass.
- **Base leak scan:** `testcharms` in `.github/workflows/_run.yml` (expect 0 hits).
- **Known issues:**
  - K1 major: build mode is changed or broken.
  - K2 minor: comments or docs still describe a `tests/`-only checkout.
  - K3 minor: an unnecessarily full juju/juju clone in snap mode.
- **Hidden checks:**
  - H1: the snap-mode tests checkout in `_run.yml` includes `testcharms` (in its sparse list, or with no sparse restriction).
  - H2: actionlint is clean.

## M1: models of other users escape cleanup (`sbx-04`)
- **Base:** `7f9937f750d926fbc17b0abfac4036c8bc4e2d39`. **Accepted:** the tree of `45293dbc775b98bf6b605b556606c4e3b04816c8` (squash of #6; includes review fix `390f25e`). **Historic:** `7d3db74` (Opus review on it: 1 minor, 1 nit).
- **Origin:** #3 review comment on `scripts/cleanup-models.sh`. Use its first two paragraphs and drop the `Fix:` line.
- **Brief (draft):**
  - Problem (quoted): "models are listed without `--all` and destroyed as `lab:<short-name>`, which resolves relative to the current user. The multi-user tests in `model` and `cli` create models this loop either doesn't see or can't address by short name. The fixed-name collision then shows up in the next iteration, or the 300 s wait runs out and the iteration scores `setup-error`."
  - R1: the harness sees and cleans up every non-controller model on the lab controller, whoever owns it.
  - R2: two users' models with the same name are handled correctly.
  - R3: offline harness cases.
  - R4: harness and shellcheck pass.
- **Base leak scan:** `models --all`, `qualified name` (expect 0 hits).
- **Known issues:**
  - K1 major: models are still destroyed by short name.
  - K2 major: the k8s namespace wait uses `owner/model` instead of the short name.
  - K3 minor: another user's model named `controller` is skipped. Only the controller model itself may be excluded.
  - K4 major: `scripts/no-models-left.sh` (the post-suite check) still lists without `--all`.
  - K5 minor: no harness case for same-named models of two users.
- **Hidden checks:** fake `juju models --all` returns `admin/m1`, `bob/m1`, `bob/controller` and `admin/controller` (`is-controller: true`); plain `juju models` returns admin's models only.
  - H1: cleanup destroys `admin/m1`, `bob/m1` and `bob/controller` by qualified name.
  - H2: cleanup never touches `admin/controller`.
  - H3: `no-models-left.sh` fails while `bob/m1` is left.
  - H4: on k8s, cleanup waits for namespace `m1`.

## M2: teardown failures scored as infra; README drift not linted (`sbx-05`)
- **Base:** `b54dc860afc5ccf2c65e6441b7f74174c87a1645`, **sanitised**. In `scenarios/sidecar-k8s/notes.md` and `README.md`, replace the sentence that starts "Until the harness fix" with "Triage a sidecar-k8s `setup-error` naming `controller-model-sidecar` as `fail`." Then check that `bash scripts/gen-suite-readme.sh --check sidecar-k8s` still exits 0.
- **Accepted:** `0397efe63dd7b4765d5573e5f4e74112270b52f4`. **Historic:** `f146fcc` (applies cleanly onto the base; checked).
- **Origin:** #7 review: the Major on `scenarios/sidecar-k8s/notes.md` line 3, and the Minor on `scripts/gen-suite-readme.sh`. Use their problem paragraphs only and drop both `Fix:` sections.
- **Brief (draft):**
  - R1: when a suite's tests don't use `run` (sidecar), a failure that surfaces after the first test has started is scored `fail`, not `setup-error`, even before any `===> [   ] Running:` marker.
  - R2: genuine infra failures before any test starts still score `setup-error`.
  - R3: lint fails when a scenario README drifts from its inputs (`skips.txt`, `alone.txt`, `notes.md`, the budget).
  - R4: offline harness cases, including a negative case for R3.
- **Base leak scan:** `second .*Reusing`, `#9` (expect 0 hits after sanitising).
- **Known issues:**
  - K1 major: a signature that appears after the second `Reusing bootstrapped juju` line still scores `setup-error`.
  - K2 major: a real setup-phase signature (one Reusing line) no longer scores `setup-error`.
  - K3 minor: the fix is special-cased in the scenario instead of `suite.sh`.
  - K4 major: the drift check isn't wired into lint, or it passes on a stale README.
  - K5 minor: no negative test for the drift check.
- **Hidden checks:** use the harness's fake `main.sh`.
  - H1: one Reusing line, then a signature, then exit 1 gives exit 2.
  - H2: two Reusing lines, then a signature, then exit 1 gives exit 1.
  - H3: a Running marker, then a signature gives exit 1.
  - H4: editing `scenarios/secrets-k8s/skips.txt` without regenerating its README makes `scripts/test-harness.sh` fail.

## M3: SLOT (blondie-devenv), with a verified fallback (`sbx-06`)
**Slot rules.** Pick a blondie-devenv change that meets all of these:
- 50–300 changed lines.
- The Opus review of Blondie's first draft had at least one major.
- The fix was accepted by Sinan.
- A pre-implementation request text exists: the issue, or Sinan's message.

Record the base, historic and accepted SHAs, the origin text, at least three known issues (from the review majors and minors) and at least two hidden checks. If none qualifies by step 8 of the runbook, use the fallback.

**Fallback: PR #8 review fix round.** This is a fix-round task, because rework rounds are part of Blondie's real workload.
- **Base:** `35570659b6b367d09e9c3f30626507e5addfddb9`. **Accepted:** `51e26c9f3f1655a9a8c595fb6695af8ee312ffef` (`b46952a` + `51e26c9`). **Historic:** none (Blondie's fix is the accepted one).
- **Brief:**
  - The three top-level review comments on #8, verbatim (`gh api repos/sinanawad/blondie-lab/pulls/8/comments`, `in_reply_to_id == null`), each with its `Fix:` list.
  - R1: address every item.
  - R2: harness and shellcheck pass.
  - Leave out the third comment's post-merge `ref=main` evidence item (it needs live runs).
- **Known issues** (each is "item not addressed or addressed wrongly"; major because it's a brief requirement):
  - K1: LXD's channel and revision missing from the verdict when LXD is set up on k8s.
  - K2: no refresh hold or drift check for that LXD.
  - K3: no `lxdbr0` wait on k8s.
  - K4: `collect.sh`'s LXD section doesn't run on k8s.
  - K5: the budget test lacks `k8s-*+charmcraft` paths.
  - K6: `bootstrap_args` isn't recorded in `verdict.json`.
  - K7: the scenario contract lacks the `requires-prompts` line.
- **Hidden checks:**
  - H1: on a fake k8s+charmcraft path, `verdict.json` has an LXD entry with channel and revision.
  - H2: `verdict.json` has `bootstrap_args` containing `mode=`.
  - H3: the budget test includes a `charmcraft` path.

## H1: charm/model type mismatch at deploy (juju/juju #22773, Go) (`sbx-07`)
- **Base:** `f498ee4eec4851d23232d39dc0b62996d8980cfa` (branch `4.0`; merge-base checked). **Accepted:** `a297343098e75aeb847ac3d101795acf1ecbddc2` (PR head; merged as `e9691979d2d941aa6b54761e557b2146a9de1378`). **Historic:** none (Sinan's PR).
- **Why it's here:** Go across three layers (domain, apiserver facade, CLI), with an additive API change. Juju maintainers (manadart, SimonRichardson) reviewed it, so the known issues are human-validated.
- **Origin:** Jira JUJU-10101. If Sinan can paste its text, use that. Otherwise use the draft below; it comes from the PR's problem paragraph only.
- **Brief (draft):**
  - Problem: "Deploying a Kubernetes (sidecar) charm to a machine model, or a machine charm to a Kubernetes model, is not something Juju guards against. Unless the charm declares `assumes: k8s-api`, both directions deploy cleanly and then break silently: the unit starts but the workload never runs. When the deploy does fail, it fails on an incidental check, typically `block storage "..." is not supported for container charms`, which never mentions the actual problem."
  - R1: `juju deploy` clearly tells the user about a mismatch in either direction, naming the charm, the model and the problem. Decide per direction whether it's an error or a warning, and justify the choice in your final message.
  - R2: covers local charm deploys and CharmHub deploys.
  - R3: correct placements produce no new output.
  - R4: API changes stay compatible with existing clients and facade versions, following Juju's facade rules.
  - R5: unit tests at each layer you touch.
  - Out of scope: bundles.
- **Sandbox base:** a single orphan commit of the tree at the base, with `.github/workflows/` deleted (writers don't need upstream CI, and the gate workflow is added later).
- **Base leak scan:** `ModelMismatch`, `IsSidecar` (expect 0 hits).
- **Known issues:**
  - K1 major: warnings are lost when the deploy also fails (the apiserver returns an empty result on error, or the client reads warnings only on success).
  - K2 major: false positives on subordinate charms, or on an empty `containers: {}` block.
  - K3 major: an incompatible API change (facade changed non-additively), or `apiserver/facades/schema.json` not regenerated.
  - K4 major: only one deploy path (local or CharmHub) is covered.
  - K5 minor: user-facing text says IAAS/CAAS instead of Kubernetes/machine.
  - K6 minor: the warning is printed after other client checks that can fail first (for example the charm format check).
  - K7 minor: a Kubernetes charm on a machine model only warns. The maintainers chose an error that `--force` downgrades.
- **Hidden checks:** none. Gates only.
- **Gate packages** (unioned with each candidate's touched packages): `./domain/deployment/charm/... ./apiserver/facades/client/application/... ./cmd/juju/application/deployer/... ./api/client/application/...`

## H2: lint workflow, fixtures and dispatch stubs (blondie-lab PR-1) (`sbx-08`)
- **Base:** `6c63ff4457c08b857e46b9b5be3cf147249368e4` (README only). **Accepted:** `16de1a885bbd3658837b8a13377f0e6d9f84bebf` (squash `fef1796`). **Historic:** `d1c8c8d096da9edea078e49135e7dc1ea67b74bf` (Opus review: 3 major, 4 minor, 4 nit).
- **Brief: SLOT.** Paste the "PR-1" section of `docs/blondie-lab-plan.md` from sinanawad/blondie-devenv verbatim, as of the last devenv commit before `2026-10-16T04:36Z`. Add the design sections it references, and nothing written later. The base README supplies the repo rules. Add an R-list that restates the plan's acceptance items. If that plan version can't be found, drop H2 and write `dropped: no pre-implementation spec` in `tasks.csv`.
- **Known issues** (#1 review):
  - K1 blocker: fork PRs get a passing `lint` through a job-level `if:` skip. A skipped job reports success, and `lint` is the required check.
  - K2 major: `persist-credentials: false` isn't enforced (zizmor `artipacked` is filtered out or not run).
  - K3 major: nothing proves zizmor's online audits ran (no online-only fixture such as impostor-commit).
  - K4 minor: the fixture check accepts any non-zero exit with the rule name anywhere, so a crashing linter passes.
  - K5 minor: lint concurrency cancels runs on `main`.
  - K6 minor: extensionless shell scripts are never shellchecked.
  - K7 minor: README says dispatching from a branch needs no review.
  - K8 nit: input-validation regexes depend on the locale.
- **Hidden checks:**
  - H1: actionlint, zizmor 1.30.1 (online, with `GH_TOKEN`) and shellcheck are clean on the candidate's tree.
  - H2: replacing each lint fixture in turn with a clean equivalent makes `scripts/check-lint-fixtures.sh` exit non-zero.
  - H3: the `lint` job has no job-level `if:`.
  - H4: every `actions/checkout` has `persist-credentials: false`.
  - H5: every `uses:` is pinned to a 40-hex SHA.

## H3: SLOT, a Juju Go change by Blondie, with a fallback (`sbx-09`)
**Slot rules.** Pick a Go change that meets all of these:
- In juju/juju or a fork, 100–600 changed lines.
- Blondie wrote the first draft, and Opus review found at least one major on it.
- The fix was accepted (merged, or approved by Sinan).
- A pre-implementation request exists (Jira, issue or Sinan's message) and doesn't contain the fixes.

Record the base (merge-base), historic and accepted SHAs, the origin text, at least three known issues and the gate packages. Build `sbx-09` like `sbx-07`.

**Fallback: blondie-lab PR-2 (harness skeleton).**
- **Base:** `fef1796bad54d3309ade915306a369172b0a4aa8`. **Accepted:** `9f6f15e9165c95c203f7f02996a3c67089085d03` (squash `bb2df90`). **Historic:** `e6882c491a31a74d879dc8acc4bd307fbbac91f3` (Opus: 4 major, 5 minor, 2 nit).
- **Brief: SLOT.** Plan "PR-2" section, plus the design sections it cites (at least the artifact and verdict section, §7), from blondie-devenv as of before `2026-10-16T05:07Z`.
- **Known issues** (#2 review):
  - K1 major: the artifact is named `invalid` whenever any check fails, even when `scenario` itself was valid.
  - K2 major: an explicit `if: steps.validate.outcome == 'success'` replaces the implicit `success()`.
  - K3 major: a harness `expect 2` case passes for the wrong gate (silent pass).
  - K4 major: verdict validity is all-or-nothing, so every echoed field is null.
  - K5 minor: if `verdict.sh` dies, nothing is uploaded.
  - K6 minor: iterations inherit `GITHUB_ENV` and related files.
  - K7 minor: the per-iteration timeout is untested.
- **Hidden checks:**
  - H1: a failing `repeat` value with a valid `scenario` yields artifact `lab-logs-<scenario>-<id>`.
  - H2: a bad `repeat` still echoes a valid `scenario` in `verdict.json`.
  - H3: removing `timeout` from `run-scenario.sh` makes the harness fail.
