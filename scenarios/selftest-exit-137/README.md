# selftest-exit-137

- **Proves:** `run.sh` exit 137 maps to verdict `error` (design §4 exit-code table), and the dispatcher (plan PR-7) mirrors it.
- **Expected verdict:** `error`. Permanent regression test; ~1 min, no Juju.
