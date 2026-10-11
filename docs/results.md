# Results

Measured from Recovery Drill run [`38123463908`](https://github.com/justrunme/kanister-backup-restore/actions/runs/38123463908) (2026-10-11). Artifacts: `recovery-evidence-k8s-v1.37.0`, `recovery-evidence-k8s-v1.36.4`.

## Happy-path drill (Postgres + S3 recovery point → restore → prove)

| Metric | k8s v1.37.0 | k8s v1.36.4 |
| --- | ---: | ---: |
| RTO (restore window) | **6 s** | **7 s** |
| RPO (pg↔s3 RP timestamp skew) | 7 s | 10 s |
| Artifact integrity | PASS | PASS |
| Application ready | PASS | PASS |
| Data verification | PASS | PASS |
| Cross-component consistency | PASS | PASS |
| Contract verdict | **PROVED** | **PROVED** |
| Contract RTO max | 60 s | 60 s |
| RP generation / objects | 1791705906 / 3 | 1791705911 / 3 |

Source evidence (v1.37.0 happy-path): `drill-20261011T080601Z.json` — `restore_actionset=restore-postgres-20261011080543`, `drill_namespace=restore-drill-20261011080543`, `rp_id=rp-20261011T080508Z-5bc472d8a7`.

Source evidence (v1.36.4 happy-path): `drill-20261011T080606Z.json` — `restore_actionset=restore-postgres-20261011080547`, `drill_namespace=restore-drill-20261011080547`, `rp_id=rp-20261011T080512Z-2997a61a91`.

## Failure drill (delete-s3-object)

| Check | Result |
| --- | --- |
| Scenario | `delete-s3-object` |
| Verdict | **UNPROVED** |
| Reason | `cross_component_consistency` |
| Blocked at | `consistency` |
| Notes | Deleted one object from the recovery point; Postgres restored but required S3 object missing |

## Failure drill (corrupt-s3-object)

| Check | Result |
| --- | --- |
| Scenario | `corrupt-s3-object` |
| Verdict | **UNPROVED** |
| Reason | `cross_component_consistency` |
| Blocked at | `consistency` |
| Notes | Corrupted one RP object; sha256 mismatch vs Postgres / manifest |

## Failure drill (mismatched-recovery-points)

| Check | Result |
| --- | --- |
| Scenario | `mismatched-recovery-points` |
| Verdict | **UNPROVED** |
| Reason | `cross_component_consistency` |
| Blocked at | `consistency` |
| Notes | Mixed old Postgres backup with newer S3 recovery-point objects |

Prometheus export from the same run (happy-path): `recovery_rto_seconds{scenario="happy-path"} 6` (v1.37.0) / `7` (v1.36.4).
