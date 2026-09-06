# Architecture

Kanister Backup & Restore treats recovery as a **control loop**, not a script on a laptop.

```text
Workload → Blueprint → ActionSet → Object store → Validate → Restore drill → Audit
```

## Components

| Piece | Responsibility |
|---|---|
| **Blueprint** | Declares backup / validate / restore / delete actions and application order |
| **Profile** | Object-store location + credentials (S3-compatible) |
| **ActionSet** | One execution of an action against a concrete object (StatefulSet, Deployment, …) |
| **Drill namespace** | Isolated restore target so production stays untouched |
| **Validation** | Proves the artifact is usable before operators trust it |

## Why not “just VolumeSnapshots”?

Snapshots are necessary but not sufficient:

- application consistency (logical dump vs dirty pages)
- secret / config reconstitution
- restore ordering across services
- operator-visible status and audit
- scheduled drills while the platform is calm

## Evidence

A successful drill leaves:

1. Blueprint + Profile applied  
2. ActionSet `complete` for backup  
3. Validation script exit `0`  
4. Restore ActionSet into `restore-drill-*`  
5. Short note of who ran it and when (CI log or ticket)

Case study: https://justrunme.com/cases/kanister-backup-restore/
