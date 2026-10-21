# repro-23659

- **What:** [juju/juju#23659](https://github.com/juju/juju/issues/23659) — deletion protection on one LXD machine makes its removal fail, and the compute provisioner then leaves a second machine's Juju record in place after that machine's container has already been deleted.
- **Reproduced means:** machine 0 is still in `juju status` with its container still present, machine 1 is still in status, and machine 1's container has been gone for 120s (step 8, case C).
- **How the batch is forced:** wait for the 12th failing provisioner exit for C0, then `remove-machine 1`. The model engine restarts the provisioner after `3 s × 1.2^(k−1)` (plan r2 §0), so after 12 exits it is down for ≥ 20 s. The next restart's first watcher event lists every machine, and machines 0 and 1 are both Dead, so that event is one `stopping known instances` batch of C0 and C1. A healthy task gives each machine its own batch, which is why a plain retry misses the bug.
- **Verdict mapping:** case D is machine 1's record and container both gone. Exit 0 only if one debug-log line contains `stopping known instances` and both container names; otherwise that shape is exit 3. With forced batching, a case D without the batch line means a timing miss.

  | Exit | Harness verdict | `result.json` `.result` | When |
  |---|---|---|---|
  | 0 | pass | `not_reproduced` | Step 8, case D |
  | 1 | fail | `reproduced` | Step 8, case C |
  | 2 | setup-error | `error` (`phase: setup`) | Steps 1 to 4 fail, or the budget runs out before step 5 |
  | 3 | inconclusive | `error` (`phase: repro`) | Steps 5 to 8 can't decide, including `precondition not reached (exits=N)` |

- **Expected verdict on e5db99d:** `fail`, meaning the bug was reproduced.
- **Pinned version:** `ref=e5db99d5854803bd30ab9ea19bf6e16bab9bbcc5`, from `sinanawad/juju` `4.1`.
- **Budget:** `TIMEOUT_MIN=30`. Expected iteration time is about 8 min: about 1 min of machines, 2–3 min of backoff wait, about 2.5 min of observing, about 1.5 min of release and cleanup. An internal deadline stops new work 6 minutes before the iteration timeout (`END = start + LAB_TIMEOUT_MIN×60 − 360`) so cleanup can finish. Repeat 1 to 3 (30×3+3+10+5 = 108 ≤ 120).
- **Diagnostics:** `lxc-*.json` keep only `name`, `status` and `protection_delete`. Raw `lxc list` JSON carries cloud-init secrets and key material, which blocks the upload ([run 39519747909](https://github.com/sinanawad/blondie-lab/actions/runs/39519747909)).
- **Safety:** delete protection is always removed before teardown.
