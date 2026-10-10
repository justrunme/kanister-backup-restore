# Changelog

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
