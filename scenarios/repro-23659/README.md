# repro-23659

- **What:** [juju/juju#23659](https://github.com/juju/juju/issues/23659) — deletion protection on one LXD machine makes its removal fail, and the compute provisioner then leaves a second machine's Juju record in place after that machine's container has already been deleted.
- **Reproduced means:** machine 0 is still in `juju status` with its container still present, machine 1 is still in status, and machine 1's container has been gone for 120s (step 8, case C).
- **Verdict mapping:** case D is machine 1's record and container both gone. Exit 0 only if one debug-log line contains `stopping known instances` and both container names; otherwise that shape is exit 3.

  | Exit | Harness verdict | `result.json` `.result` | When |
  |---|---|---|---|
  | 0 | pass | `not_reproduced` | Step 8, case D |
  | 1 | fail | `reproduced` | Step 8, case C |
  | 2 | setup-error | `error` (`phase: setup`) | Steps 1 to 4 fail, or the budget runs out before step 5 |
  | 3 | inconclusive | `error` (`phase: repro`) | Steps 5 to 8 can't decide |

- **Expected verdict on e5db99d:** `fail`, meaning the bug was reproduced.
- **Pinned version:** `ref=e5db99d5854803bd30ab9ea19bf6e16bab9bbcc5`, from `sinanawad/juju` `4.1`.
- **Budget:** `TIMEOUT_MIN=30`, uncalibrated, with an internal deadline that stops new work 6 minutes before the iteration timeout (`END = start + LAB_TIMEOUT_MIN×60 − 360`) so cleanup can finish. Repeat 1 to 3 (30×3+3+10+5 = 108 ≤ 120).
- **Safety:** delete protection is always removed before teardown.
