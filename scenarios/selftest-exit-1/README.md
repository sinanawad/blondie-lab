# selftest-exit-1

- **Proves:** `run.sh` exit 1 maps to verdict `fail` (design §4 exit-code table), and the dispatcher (plan PR-7) mirrors it.
- **Expected verdict:** `fail`. Permanent regression test; ~1 min, no Juju.
