# selftest-flaky

- **Proves:** repeat aggregation (design §4): a failed iteration beats a later pass, every result is kept, and the summary shows k/N.
- **Expected verdict:** with `repeat=3`: `fail`, 1/3 failed (iteration 2). With `repeat=1`: `pass`.
- ~1 min, no Juju.
