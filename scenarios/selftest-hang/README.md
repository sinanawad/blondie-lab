# selftest-hang

- **Proves:** the per-iteration `timeout` (TIMEOUT_MIN=1) cuts a hung `run.sh` (exit 124 → verdict `error`), and the loop stops after it (repeat=2 records exactly 1 result).
- **Expected verdict:** `error`, `results[0].exit_code == 124`. Permanent regression test; ~1-2 min, no Juju.
