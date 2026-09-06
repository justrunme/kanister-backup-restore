# Architecture — Recovery Contract

```text
PROTECT → VALIDATE → RESTORE → PROVE
```

Kanister is the execution engine (Blueprints, ActionSets, Profiles).  
This repository is the **assurance layer**: a Recovery Contract with a binary verdict.

## Contract

See `config/recovery-contract.yaml`:

- artifact integrity — required
- isolated restore — required
- application ready — required
- data verification — required
- RTO — &lt; 60s
- evidence freshness — &lt; 24h

**PROVED** only when every clause passes.  
Otherwise **UNPROVED** with an explicit `Reason`.

No percentage scores.

## Failure injection

`make failure-drill SCENARIO=corrupt-artifact` (and siblings) prove when confidence must collapse — separately from the happy path.

## Visual

`docs/assets/recovery-lifecycle.svg`

## Case study

https://justrunme.com/cases/kanister-backup-restore/
