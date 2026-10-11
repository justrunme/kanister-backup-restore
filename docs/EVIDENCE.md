# Evidence

Maps Recovery Contract claims to CI proof. Status vocabulary: **Tested in CI** /
**Reference implementation** / **Simulated** / **Not yet**.

Numbers below are taken from [docs/results.md](results.md) / [docs/results.json](results.json)
and the linked Recovery Drill artifacts. **Kind-based RTO/RPO (single-node lab Postgres)
do not represent large production datasets or enterprise backup fabrics.**

## Claim table

| Claim | Status | Scenario + environment | Real limits | Proof link | Negative tests |
| --- | --- | --- | --- | --- | --- |
| Happy-path PROTECT → VALIDATE → RESTORE → PROVE (PROVED) | Tested in CI | Recovery Drill workflow; kind matrix **k8s v1.37.0** and **v1.36.4**; Postgres + S3 (SeaweedFS) linked recovery point | Single-node kind; tiny demo DB+objects; RTO is restore+prove duration in that lab — **not** warehouse-scale RTO | Documented run [38131463362](https://github.com/justrunme/kanister-backup-restore/actions/runs/38131463362) ([docs/results.md](results.md) / [results.json](results.json)): RTO **8 s** / **8 s**, component skew **13 s** / **9 s**, verdict **PROVED**, components `postgres`+`s3` true; RP `rp-20261011T101959Z-878b148bde` / `rp-20261011T102003Z-dccc3c2681`. Post-merge Recovery Drill: [38133272732](https://github.com/justrunme/kanister-backup-restore/actions/runs/38133272732) | Contract fails closed on failed clauses; delete/corrupt/mismatch drills → **UNPROVED** |
| Artifact integrity (sha256 + scratch SQL) | Tested in CI | Same drills | Lab object in MinIO | Same runs/artifacts; corrupt path below | `corrupt-artifact` → **UNPROVED** / `artifact_integrity`, blocked at `validate` |
| Unique marker + checksum data verification after restore | Tested in CI | Happy-path proof marker UUID in evidence JSON | Proves the restored row, not full logical replication lag across regions | results.json marker/restore_actionset fields; latest artifacts include `proof.marker_uuid` | `noop-restore` → **UNPROVED** / `data_verification` (ActionSet completed without applying expected data) |
| Fail-closed evaluator / contract gating | Tested in CI | Evaluator unit tests in CI + failure drills in Recovery Drill | Contract JSON/YAML as configured (`config/recovery-contract.*`) | CI + Recovery Drill on main after #17 | UNPROVED verdicts for noop-restore and corrupt-artifact |
| Continuous recovery confidence across large prod datasets | Not yet | — | No multi-TB / multi-hour restore evidence in-repo | — | — |

## Not proven / out of scope

- Large production dataset RTO/RPO (explicitly out of scope for kind numbers)
- Cross-region DR, backup immutability compliance audits, or vendor Kanister SaaS SLAs
- Treating ~8 s kind RTO as a contractual enterprise target

## How to reproduce

```bash
make full-drill
# or
make recovery-drill
```

CI: `.github/workflows/recovery-drill.yml` (and `ci.yml` evaluator checks).
