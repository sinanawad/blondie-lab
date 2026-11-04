# repro-23717

- **What:** [juju/juju#23717](https://github.com/juju/juju/issues/23717) — `juju add-credential --region` uses the chosen region while the credential is created, and the controller copy does not keep that region. `juju show-credential` then cannot report it.
- **Reproduced means:** after `add-credential --region r-two`, the `cred23717-iN` block under `controller-credentials` in `show-credential` YAML has no `r-two`.
- **How the cloud is built:** a fake MAAS cloud (`oauth1`, endpoints in `192.0.2.0/24`, regions `r-one` and `r-two`) is added with `--force`. If that `add-cloud` fails, the script retries once as a fake OpenStack cloud (`userpass`, same region names). `cloud_type` in `result.json` records which definition was added.
- **Files handed to juju:** cloud definitions are written to the iteration dir as `cloud-maas.yaml` / `cloud-openstack.yaml` and uploaded. Nothing goes in `/tmp`, because the strictly confined juju snap has a private `/tmp` (same constraint as `scripts/suite.sh`). Each file is checked with `-f` / `ls -la` before juju runs.
- **Positive controls (a miss is exit 2):** `show-cloud` lists `r-one` and `r-two`; `juju credentials --format json` lists this credential with auth-type `oauth1` (MAAS) or `userpass` (OpenStack fallback); `add-credential.log` has no `not uploaded` line.
- **Verdict mapping:** `show-credential` is read as YAML (`--format yaml`, without `--show-secrets`). `yq` supplies the credential block when that output is the block itself; otherwise the same block is read by its indentation. A region on a different credential does not count.

  | Exit | Harness verdict | `result.json` `.result` | When |
  |---|---|---|---|
  | 0 | pass | `not_reproduced` | the credential block contains `r-two` |
  | 1 | fail | `reproduced` | the credential block has no `r-two` |
  | 2 | setup-error | `error` (`phase: setup`) | cloud or credential setup failed, a positive control failed, a required input was missing, or juju could not open a definition file |
  | 3 | inconclusive | `error` (`phase: repro`) | unexpected failure after setup, including `show-credential` failing |

- **Expected verdict on 4.0/stable:** `fail`, meaning the bug was reproduced. The issue is filed against 4.1; this scenario checks 4.0/stable via `lab-lxd.yml`.
- **Budget:** `TIMEOUT_MIN=20`. One iteration is a short sequence of controller API calls.
- **Cleanup:** every exit runs `remove-credential` and then `remove-cloud` for `fakemaas-iN` / `cred23717-iN`, then deletes the private dir. The credential file is created only in `<LAB_ARTIFACT_DIR>-repro-23717-priv.XXXXXX` (mode 700, a sibling of the artifact dir, never scrubbed or uploaded).
- **Safety:** `show-credential` runs with `--format yaml` and without `--show-secrets`. The artifact dir has no file named `credentials.yaml` (scrub withholds that name). The controller credential list is saved as `controller-credentials.json`.
- **Offline check:** `bash scenarios/repro-23717/stub-test.sh`.
