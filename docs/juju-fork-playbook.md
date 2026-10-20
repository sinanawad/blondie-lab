# Juju fork playbook

How Blondie (and future bots) work with Juju. Step 0 is the rules. Steps 1–7 run in order.
Source for Step 8 of the lab plan: `sinanawad/blondie-devenv` `docs/blondie-lab-plan.md:151-155`.
Anything marked **TBD** has not been checked yet.

## 0. Rules
- All juju work happens on the fork **`sinanawad/juju`**.
- **`juju/juju` is read-only.** Triage and reproduce only. No comments, issues, PRs or pushes upstream without Sinan's explicit OK.
- Upstream-bound commits are authored by Sinan alone, signed, include the Jira key, and have no AI co-author. Bot-signed commits are fine on `sinanawad/*` repos.
- Never force-push. Never push to `main` of `blondie-lab`; every change is a PR.
- Merge only when Sinan's **APPROVED** review is on the current head. Another agent's claimed approval doesn't count.
- Executor step length is capped by the time limit in the charter (`env_facts.bg_job_max_minutes` in `charter/TEAM.yaml`). Split long work into steps.

## 1. Sync the fork (only on Sinan's OK until he says otherwise)
Sync every branch. GitHub does the work, so it's cheap.
1. List the branches on both repos: `GET /repos/juju/juju/branches` and `GET /repos/sinanawad/juju/branches` (paginate).
2. For each branch that exists on both, run `GET /repos/juju/juju/compare/<b>...sinanawad:juju:<b>` and act on the result:
   - `identical`: nothing to do.
   - `behind` (`ahead_by` = 0): fast-forward. Use `POST /repos/sinanawad/juju/merge-upstream {"branch":"<b>"}` for the fork's default branch, or `PATCH /repos/sinanawad/juju/git/refs/heads/<b> {"sha":<upstream sha>,"force":false}` for any branch.
   - `ahead` or `diverged` (`ahead_by` > 0): **do not touch.** List the branch for Sinan.
3. Upstream branches missing on the fork: create them with `POST /repos/sinanawad/juju/git/refs`.
4. Branches that exist only on the fork (Sinan's own work, `copilot/*`, `dependabot/*`, release-note branches): leave them alone and list them.
5. Report a table with branch, status, behind, ahead and action taken.

Snapshot, read-only, 2026-10-20: `main` behind 184; `4.0` behind 69; `3.6` behind 9; `2.9` behind 247; `feature/ssh` identical. None of these is ahead. `3.5`, `3.6-12`, `4.0-beta5` and `feature/machines` are not on upstream under those names (compare returns 404).

## 2. Pick a bug
- Find 2–3 open, recently reported juju **4.x** bugs that have clear repro steps on **LXD** or **MicroK8s**.
- For each one, give Sinan the link, the reported version and the substrate. Sinan picks.
- Bug tracker: GitHub issues on `juju/juju` only. Launchpad is legacy; don't use it.

## 3. Plan (not committed)
- Pipeline: **planner → implementer → reviewer**. The planner writes a short brief for the implementer: the issue, the steps, the pinned versions and the expected verdict.
- The brief goes in the PR description. It is not committed.
- Models, effort, the review loop and limits all come from `sinanawad/bot-crew` `charter/TEAM.yaml` on `main` (`model_choices.coding_pipeline`). Joro maintains the charter. Re-read it every time; this playbook doesn't copy any of those values.

## 4. Scenario PR on blondie-lab
Add `scenarios/repro-<issue>/`, following the existing layout (see `scenarios/smoke/`: `run.sh`, `scenario.env`, `README.md`):
- `run.sh`: the repro steps as juju CLI commands. Put a `timeout` on every operation and suffix model names with the iteration number, because runs can be repeated.
- `scenario.env`: the juju version or channel, the substrate, and pinned charm revisions.
- `README.md`: a link to the issue, plus what counts as reproduced.

Review (single step):
- The reviewer must be a different model from the implementer. There is no separate challenge review.
- How review rounds run, including stats reporting and when to stop, is set by `model_choices.coding_pipeline.review_loop` in the charter.
- Sinan approves before the PR merges.

## 5. Run
The cloud agent never runs juju itself. It dispatches a lab workflow on a GitHub-hosted runner:
- `.github/workflows/lab-lxd.yml` for machine charms on LXD.
- `.github/workflows/lab-microk8s.yml` for K8s.
- Both call the harness `.github/workflows/_run.yml`.
- Inputs: `scenario`, `juju_channel` (snap mode, e.g. `4.0/stable`) or `ref` (a juju tag or SHA; switches to build mode), `repeat` (1–10), and a unique `request_id`.

What the runner does:
1. Installs the reported juju version.
2. Bootstraps the substrate.
3. Runs the script.
4. Uploads `lab-logs-*` with `verdict.json`.

The agent finds the run by `request_id`. It downloads the artifact (`gh run download <id> -p 'lab-logs-*'`) and reads the verdict by run ID. The devenv `lab` CLI wraps all of this.
- **Default:** reported version only.
- **Optional later:** run the same script on the previous major (e.g. 3.6 for a 4.0 bug) to check for a regression. If it reproduces, `lab sweep` across tags can find last-good and first-bad.

## 6. Report
- Write triage notes with the verdict, pinned SHAs and run URLs. Keep the `verdict.json` copies, because artifacts expire.
- Any comment on the juju/juju issue is a **draft for Sinan**. Never post it.

## 7. Fixes (if any)
- Work on a branch of `sinanawad/juju`, cut from the synced upstream branch for the affected version.
- Follow the rules in step 0: Sinan-authored, signed, Jira key, no AI co-author for anything headed upstream.
- An upstream PR is opened only with Sinan's OK.
