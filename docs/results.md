# Results

Measured from Recovery Drill run [`38118145078`](https://github.com/justrunme/kanister-backup-restore/actions/runs/38118145078) (2026-10-11). Artifacts: `recovery-evidence-k8s-v1.37.0`, `recovery-evidence-k8s-v1.36.4`.

## Happy-path drill (backup → restore → prove)

| Metric | k8s v1.37.0 | k8s v1.36.4 |
| --- | ---: | ---: |
| RTO (restore ActionSet duration) | **6 s** | **5 s** |
| RPO (backup_ts − marker_ts) | 12 s | 11 s |
| Artifact integrity (sha256 + scratch SQL) | PASS | PASS |
| Application ready | PASS | PASS |
| Data verification (exact marker + checksum) | PASS | PASS |
| Contract verdict | **PROVED** | **PROVED** |
| Contract RTO max | 60 s | 60 s |

Source evidence (v1.37.0 happy-path): `drill-20261011T063025Z.json` — `restore_actionset=restore-postgres-20261011063010`, `drill_namespace=restore-drill-20261011063010`, marker `ad654415-eb35-4594-992f-c795c78fb617`.

## Failure drill (noop-restore)

| Check | Result |
| --- | --- |
| Scenario | `noop-restore` |
| Verdict | **UNPROVED** |
| Reason | `data_verification` |
| Notes | Restore ActionSet completed without applying data; unseeded DB lacked the pre-backup marker |

## Failure drill (corrupt-artifact)

| Check | Result |
| --- | --- |
| Scenario | `corrupt-artifact` |
| Verdict | **UNPROVED** |
| Reason | `artifact_integrity` |
| Blocked at | `validate` |

Prometheus export from the same run (happy-path): `recovery_rto_seconds{scenario="happy-path"} 6` (v1.37.0) / `5` (v1.36.4).
