# selftest-exit-2

- **Proves:** `run.sh` exit 2 maps to verdict `setup-error` (design §4 exit-code table), and the dispatcher (plan PR-7) mirrors it.
- **Expected verdict:** `setup-error`. Permanent regression test; ~1 min, no Juju.
