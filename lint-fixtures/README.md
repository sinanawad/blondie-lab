# lint-fixtures

Known-bad files. Each one must make its linter fail; `scripts/check-lint-fixtures.sh`
(run by `lint.yml` on every PR and push) asserts that. They live outside
`.github/workflows/`, so GitHub never runs them. Do not "fix" them.

| File | Linter | Expected finding |
|---|---|---|
| `bad-injection.yml` | zizmor | `template-injection` (`${{ github.event.pull_request.title }}` in `run:`) |
| `unpinned-action.yml` | zizmor (with `zizmor.yml` hash-pin policy) | `unpinned-uses` (`actions/checkout@v4`) |
| `actionlint-bad.yml` | actionlint | `syntax-check` (unknown key) / `expression` (bad expression) |
| `sc2086.sh` | shellcheck | `SC2086` (unquoted variable) |
