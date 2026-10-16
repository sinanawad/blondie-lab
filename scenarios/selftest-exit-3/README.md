# selftest-exit-3

- **Proves:** `run.sh` exit 3 maps to verdict `inconclusive` (design §4 exit-code table), and the dispatcher (plan PR-7) mirrors it.
- **Expected verdict:** `inconclusive`. Permanent regression test; ~1 min, no Juju.
