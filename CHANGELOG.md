# Changelog

## Unreleased

### Fixed
- Compute `components.postgres` / `components.s3` from real restore+verification results (never hardcode true); CI asserts `s3=false` on delete-s3-object
- Scope operator RBAC: namespaced Role in kanister + per-namespace RoleBindings for drill ns (no cluster-wide secrets)
- Rename `rpo_seconds` → `component_skew_seconds` (honest RPO not claimed without last-write timestamp)
- `restore_completed` requires Postgres and S3 restore; S3 restore lands in a fresh app prefix the app check reads
- Operator runs drills asynchronously (`DRILL_INLINE`/Job); clears stuck `phase=Running`; `break.sh` failures fail the operator; kind CI asserts status
- Secret-leak check fails if zero pods checked; `prove_consistency` fails on empty data; remove empty-array masking

## [1.2.0] - 2026-10-11

Multi-service Application Recovery Contract (Postgres + S3):

- Linked demo state (object key + sha256 + generation) under one logical recovery point
- Cross-component consistency proof; PROVED only when components and consistency pass
- Negative drills: `delete-s3-object`, `corrupt-s3-object`, `mismatched-recovery-points`
- CRDs `RecoveryContract` / `RecoveryDrill` + kopf operator; ResourceQuota/LimitRange on drill namespaces
- Metrics: `recovery_last_success_timestamp` alongside verdict/RTO
- Solr listed as future scope

## [1.1.0] - 2026-10-11

Restore proof hardening (Recovery Contract must not false-positive):

- Pre-backup unique marker (uuid + timestamp); restore into unseeded DB; PROVE matches exact marker + row checksum
- Negative scenario `noop-restore` → `UNPROVED` / `data_verification`
- Unique backup object keys with sha256 metadata; retention (`BACKUP_RETAIN_N`); VALIDATE verifies sha256 + scratch SQL restore
- S3 credentials only via Kanister Profile (`toJson .Profile`); no `set -x` in blueprint phases
- Evaluator computes real evidence age, reads RTO from contract, exits `2` on UNPROVED; pytest coverage

## [1.0.0] - 2026-10-10

First stable release of the Kanister Recovery Contract pack:
PROTECT → VALIDATE → RESTORE → PROVE with binary **PROVED** / **UNPROVED** verdicts.

- Real recovery drill in CI on kind (Kubernetes v1.37 / v1.36): `full-drill` must be **PROVED**, `failure-drill SCENARIO=corrupt-artifact` must be **UNPROVED**
- SeaweedFS S3-compatible object storage (replaces MinIO for public image pulls)
- Centralized tool and component versions in `config/versions.env`
- Prometheus metrics (`recovery_contract_verdict`, `recovery_rto_seconds`, `recovery_evidence_age_hours`) and `deploy/prometheus-rules.yaml` alerts
- shellcheck and shfmt gates in CI; scripts formatted

## 0.4.0 — 2026-09-06

- **Recovery Contract** replaces percentage confidence scoring
- Binary verdict: **PROVED** / **UNPROVED** with explicit Reason
- Lifecycle: **PROTECT → VALIDATE → RESTORE → PROVE**
- `make failure-drill SCENARIO=…` for deliberate failure modes
- Drill evidence card with RPO / RTO / evidence age
- README visual: `docs/assets/recovery-lifecycle.svg`

## 0.3.0 — 2026-09-06

- Continuous Recovery Confidence prototype (score + SLO + break scenarios)

## 0.2.0 — 2026-09-06

- Real Postgres Blueprint with kando push/pull, MinIO Profile, seeded demo, full-drill

## 0.1.0 — 2026-09-06

- Initial public scaffold
