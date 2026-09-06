# Architecture

Kanister Backup & Restore treats recovery as a **control loop**.

```text
Workload → Blueprint → ActionSet → Object store (Profile) → Validate → Restore drill → Evidence
```

## Control plane pieces

| Piece | Role |
|---|---|
| **Blueprint** | Declares backup / validate / restore / delete with application semantics |
| **Profile** | S3-compatible location + credentials (MinIO in Kind drills) |
| **ActionSet** | One execution against a concrete object (StatefulSet / Deployment) |
| **kando** | Streams artifacts to/from the Profile (`location push/pull/delete`) |
| **Drill namespace** | Isolated restore target (`restore-drill-*`) |
| **Evidence** | Markdown snapshot of ActionSets + artifact path |

## Postgres path (default drill)

1. Seed table `recovery_markers` in `demo-postgres`
2. `pg_dump --clean --if-exists | gzip | kando location push`
3. Validate with `gzip -t` + SQL head sniff
4. Restore into a new namespace with the same Secret/Service contract
5. Query `recovery_markers` to prove data returned

## Failure philosophy

Validation failures are **hard failures**.  
A backup that cannot be pulled and inspected is not a backup.

## Case study

https://justrunme.com/cases/kanister-backup-restore/
