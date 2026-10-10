# Results

Measured from Recovery Drill run [`38061727612`](https://github.com/justrunme/kanister-backup-restore/actions/runs/38061727612) (2026-10-10). Artifacts: `recovery-evidence-k8s-v1.37.0`, `recovery-evidence-k8s-v1.36.4`.

## Happy-path drill (backup → restore → prove)

| Metric | k8s v1.37.0 | k8s v1.36.4 |
| --- | ---: | ---: |
| RTO (restore duration) | **16 s** | **16 s** |
| RPO | 26 s | 25 s |
| Artifact integrity | PASS | PASS |
| Application ready | PASS | PASS |
| Data verification | PASS | PASS |
| Contract verdict | **PROVED** | **PROVED** |
| Contract RTO max | 60 s | 60 s |

Source evidence (v1.37.0 happy-path): `drill-20261010T150101Z.json` — `restore_actionset=restore-postgres-20261010150045`, `drill_namespace=restore-drill-20261010150045`.

## Failure drill (corrupt-artifact)

| Check | Result |
| --- | --- |
| Scenario | `corrupt-artifact` |
| Verdict | **UNPROVED** |
| Reason | `artifact_integrity` |
| Blocked at | `validate` |

Prometheus export from the same run: `recovery_rto_seconds{scenario="happy-path"} 16`.
