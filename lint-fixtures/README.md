# lint-fixtures

Known-bad files. Each one must make its linter fail with a real finding;
`scripts/check-lint-fixtures.sh` (run by `lint.yml` on every PR and push) asserts
the exit-code class and the rule id. They live outside `.github/workflows/`, so
GitHub never runs them. Do not "fix" them.

| File | Linter | Expected finding |
|---|---|---|
| `bad-injection.yml` | zizmor | `template-injection` (`${{ github.event.pull_request.title }}` in `run:`) |
| `unpinned-action.yml` | zizmor | `unpinned-uses` (`actions/checkout@v4`; hash-pin policy, the 1.30.1 default, kept explicit in `zizmor.yml`) |
| `no-persist-credentials.yml` | zizmor | `artipacked` (pinned checkout without `persist-credentials: false`; low severity online, hence `--min-severity low`) |
| `impostor-commit.yml` | zizmor, online only | `impostor-commit` (fork-network-only SHA). Proves zizmor ran online with `GH_TOKEN` |
| `actionlint-bad.yml` | actionlint | `syntax-check` (unknown key) **and** `expression` (bad expression) |
| `sc2086.sh` | shellcheck | `SC2086` (unquoted variable) |
