# Architecture — Continuous Recovery Confidence

```text
Protect → Break → Restore → Prove
```

## Control loop

```text
Workload
  → Kanister Blueprint / ActionSet (backup)
  → Object store artifact (Profile)
  → Validate (gzip + SQL head)
  → Isolated restore-drill-* namespace
  → Application + data verification
  → Deterministic confidence score + Recovery SLO
  → Evidence (.evidence/)
```

## Why not “just Kanister”?

Kanister is the execution engine (Blueprints, ActionSets, Profiles).  
This repository is the **assurance layer**: continuous proof that a backup is still recoverable against explicit objectives.

## Score

See `config/recovery-slo.yaml` — weights sum to 100.  
No randomness. Failed checks contribute zero.

## States

`UNPROVEN → VALIDATED → RESTORED → VERIFIED → PROVED`

## Failure injection

Break scenarios exist to show *when* confidence must collapse — not to decorate the happy path.

## Case study

https://justrunme.com/cases/kanister-backup-restore/
