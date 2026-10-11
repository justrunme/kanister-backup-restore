# Changelog

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
