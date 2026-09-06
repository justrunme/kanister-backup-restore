# Continuous Recovery Confidence

**Restore should be proved, not assumed.**

A backup is not successful when it is created.  
It is successful when its **recovery has been proved** — continuously, against Recovery SLOs, with evidence.

[![CI](https://github.com/justrunme/kanister-backup-restore/actions/workflows/ci.yml/badge.svg)](https://github.com/justrunme/kanister-backup-restore/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Case study](https://img.shields.io/badge/case-justrunme.com-111111)](https://justrunme.com/cases/kanister-backup-restore/)

Case study: [Kanister Backup & Restore](https://justrunme.com/cases/kanister-backup-restore/) · [Andrey Lesnikov](https://justrunme.com/)

```text
Protect → Break → Restore → Prove
```

---

## The idea

Kanister already gives you Blueprints, ActionSets, and Profiles.  
This repository adds the missing platform layer:

**Continuous Recovery Confidence** — deterministic scoring of whether you should trust a specific backup *right now*.

```text
BACKUP → ARTIFACT → VALIDATE → ISOLATED RESTORE → VERIFY APP → EVIDENCE → CONFIDENCE
```

| State | Meaning |
|---|---|
| `UNPROVEN` | No successful validation yet |
| `VALIDATED` | Artifact integrity proved |
| `RESTORED` | Isolated restore completed |
| `VERIFIED` | App healthy + data markers present |
| `PROVED` | All checks + RTO + fresh evidence |

### Deterministic score (never random)

| Check | Points |
|---|---:|
| Artifact integrity | 20 |
| Restore completed | 25 |
| Application health | 20 |
| Data verification | 20 |
| RTO within target | 10 |
| Evidence fresh | 5 |
| **Total** | **100** |

### Recovery SLO

Production SLOs ask: *is the service up?*  
Recovery SLOs ask: *if it disappears now, how sure are we we can bring it back?*

```text
Restore success     required
RTO                 < 60s
Evidence age        < 24h
Artifact integrity  PASS
Data verification   PASS
→ RECOVERY SLO      MET | BREACHED
```

---

## Quickstart

```bash
make full-drill
```

Happy path ends in a console card:

```text
RECOVERY CONFIDENCE
State           PROVED
Confidence       100 / 100
Recovery SLO    MET
```

Evidence lands in `.evidence/recovery-confidence.md`.

---

## Deliberately break it

Prove which failure modes make a backup worthless:

```bash
make scenario-corrupt   # VALIDATE fails · confidence collapses
make scenario-secret    # RESTORE auth fails
make scenario-schema    # DATA VERIFY fails after restore
make scenario-rto       # RTO breaches Recovery SLO
```

Or arm manually:

```bash
make backup-drill
make break-backup       # corrupt object in MinIO
make recovery-drill     # expect VALIDATED? no — blocked at validate
```

| Scenario | Blocked at | What you learn |
|---|---|---|
| `corrupt-artifact` | validate | Creation ≠ recoverability |
| `wrong-secret` | restore | Credentials are part of the recovery contract |
| `schema-drift` | verify | Bytes restored ≠ application verified |
| `slow-restore` | rto | Success without RTO still BREACHES Recovery SLO |

---

## Make targets

| Target | Purpose |
|---|---|
| `make full-drill` | Kind + Kanister + MinIO + happy-path prove |
| `make recovery-drill` | Protect → optional break → restore → confidence |
| `make confidence` | Recompute score/SLO from latest evidence JSON |
| `make break-*` / `scenario-*` | Failure injection demos |
| `make evidence` | ActionSet inventory markdown |

---

## Layout

```text
config/recovery-slo.yaml     Weights + SLO targets
scripts/recovery-drill.sh    Prove loop
scripts/break.sh             Failure injection
scripts/compute-confidence.sh
blueprints/postgres/         Real pg_dump + kando push/pull
deploy/minio-profile.yaml
.evidence/                   Drill JSON + confidence reports
```

---

## Philosophy

Same school as the rest of the platform work:

| Project | Prove |
|---|---|
| Architecture Rehearsal | the change |
| TwinOps | state convergence |
| AI Infra Control Plane | governance decisions |
| **This repo** | **recovery** |

Assumptions → evidence.

---

## License

Apache-2.0 © Andrey Lesnikov
