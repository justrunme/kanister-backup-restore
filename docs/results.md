# Recovery Contract results

Source run: [https://github.com/justrunme/kanister-backup-restore/actions/runs/38131094351](https://github.com/justrunme/kanister-backup-restore/actions/runs/38131094351)

Measured at: `2026-10-11T10:17:58Z` (UTC)

## Happy path (PROVED)

| k8s | RTO (s) | component skew (s) | RP | objects | components |
|---|---:|---:|---|---:|---|
| v1.37.0 | 7 | 9 | `rp-20261011T101400Z-92eb9aecca` | 3 | `{'postgres': True, 's3': True}` |
| v1.36.4 | 7 | 13 | `rp-20261011T101404Z-068a868205` | 3 | `{'postgres': True, 's3': True}` |

## Failure scenarios (UNPROVED)

| scenario | reason | blocked_at |
|---|---|---|
| delete-s3-object | isolated_restore | restore |
| corrupt-s3-object | cross_component_consistency | consistency |
| mismatched-recovery-points | data_verification | verify |

Contract ceilings: RTO ≤ 60s, component skew ≤ 60s.

Machine-readable: [`results.json`](./results.json).
