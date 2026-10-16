# selftest

- **Proves:** the harness path without Juju: dispatch, input validation, the iteration loop, `verdict.json`, job summary, artifact upload, and that the caller can find and download the run (design Q6).
- **Expected verdict:** `pass`, one result per iteration, a `selftest-<i>.txt` per iteration in the artifact.
- **Substrate:** any (no bootstrap). ~1 min.
