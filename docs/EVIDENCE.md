# Evidence

Maps Recovery Contract claims to CI proof. Status vocabulary: **Tested in CI** /
**Reference implementation** / **Simulated** / **Not yet**.

Numbers below are taken from [docs/results.md](results.md) / [docs/results.json](results.json)
and the linked Recovery Drill artifacts. **Kind-based RTO/RPO (single-node lab Postgres)
do not represent large production datasets or enterprise backup fabrics.**

## Claim table

| Claim | Status | Scenario + environment | Real limits | Proof link | Negative tests |
| --- | --- | --- | --- | --- | --- |
| Happy-path PROTECT → VALIDATE → RESTORE → PROVE (PROVED) | Tested in CI | Recovery Drill workflow; kind **v0.33.0**; matrix **k8s v1.37.0** and **v1.36.4**; MinIO object store; Postgres blueprint | Single-node kind; tiny demo DB; RTO is restore ActionSet duration in that lab — **not** warehouse-scale RTO | Documented run [38118145078](https://github.com/justrunme/kanister-backup-restore/actions/runs/38118145078) (results.md): RTO **6 s** / **5 s**, RPO **12 s** / **11 s**, verdict **PROVED**; artifacts `recovery-evidence-k8s-v1.37.0` / `…v1.36.4`; v1.37 marker `ad654415-eb35-4594-992f-c795c78fb617`, backup sha256 `6a8db462604d015d03548c662db2333c028fe9538e1f5a7fce113e13e0cb0aab`. Post-merge main confirmation: [38121276465](https://github.com/justrunme/kanister-backup-restore/actions/runs/38121276465) · SHA `3ad805c55662b93f821a9753a1c76ddec912918f` (happy-path PROVED; artifact RTO example **5 s** on v1.37.0) | Contract fails closed on failed clauses |
| Artifact integrity (sha256 + scratch SQL) | Tested in CI | Same drills | Lab object in MinIO | Same runs/artifacts; corrupt path below | `corrupt-artifact` → **UNPROVED** / `artifact_integrity`, blocked at `validate` |
| Unique marker + checksum data verification after restore | Tested in CI | Happy-path proof marker UUID in evidence JSON | Proves the restored row, not full logical replication lag across regions | results.json marker/restore_actionset fields; latest artifacts include `proof.marker_uuid` | `noop-restore` → **UNPROVED** / `data_verification` (ActionSet completed without applying expected data) |
| Fail-closed evaluator / contract gating | Tested in CI | Evaluator unit tests in CI + failure drills in Recovery Drill | Contract JSON/YAML as configured (`config/recovery-contract.*`) | CI + Recovery Drill on main after #17 | UNPROVED verdicts for noop-restore and corrupt-artifact |
| Continuous recovery confidence across large prod datasets | Not yet | — | No multi-TB / multi-hour restore evidence in-repo | — | — |

## Not proven / out of scope

- Large production dataset RTO/RPO (explicitly out of scope for kind numbers)
- Cross-region DR, backup immutability compliance audits, or vendor Kanister SaaS SLAs
- Treating ~5–16 s kind RTO as a contractual enterprise target

## How to reproduce

```bash
make full-drill
# or
make recovery-drill
```

CI: `.github/workflows/recovery-drill.yml` (and `ci.yml` evaluator checks).
