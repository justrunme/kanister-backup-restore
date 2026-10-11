# Recovery Contract results

Source run: [https://github.com/justrunme/kanister-backup-restore/actions/runs/38131463362](https://github.com/justrunme/kanister-backup-restore/actions/runs/38131463362)

Measured at: `2026-10-11T10:23:50Z` (UTC)

## Happy path (PROVED)

| k8s | RTO (s) | component skew (s) | RP | objects | components |
|---|---:|---:|---|---:|---|
| v1.37.0 | 8 | 13 | `rp-20261011T101959Z-878b148bde` | 3 | `{'postgres': True, 's3': True}` |
| v1.36.4 | 8 | 9 | `rp-20261011T102003Z-dccc3c2681` | 3 | `{'postgres': True, 's3': True}` |

## Failure scenarios (UNPROVED)

| scenario | reason | blocked_at | components |
|---|---|---|---|
| delete-s3-object | isolated_restore | restore | `{'postgres': False, 's3': False}` |
| corrupt-s3-object | cross_component_consistency | consistency | `{'postgres': True, 's3': False}` |
| mismatched-recovery-points | data_verification | verify | `{'postgres': False, 's3': False}` |

Contract ceilings: RTO ≤ 60s, component skew ≤ 60s.

Machine-readable: [`results.json`](./results.json).
