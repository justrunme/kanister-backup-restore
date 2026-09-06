# Restore drill runbook

Goal: prove restore works **before** an incident.

## Preconditions

- [ ] Kind (or target) cluster is up
- [ ] Kanister operator healthy (`kubectl -n kanister get pods`)
- [ ] Profile points at reachable object storage
- [ ] Blueprints applied
- [ ] Demo (or real) workload ready

## Procedure

```bash
make backup-drill
make validate-backup
make restore-drill
```

## Pass criteria

- Backup ActionSet reaches `complete`
- `validate-backup` exits 0
- Restore ActionSet reaches `complete` in an isolated namespace
- Application readiness probe passes in the drill namespace (when wired)

## Fail criteria

- ActionSet `failed` / stuck `running`
- Empty artifact path
- Validation skipped “because backup looked fine”
- Restore performed into production namespace

## Aftercare

- Delete drill namespace: `kubectl delete ns -l justrunme.com/role=restore-drill`
- Keep backup artifacts according to retention Profile
- File gaps as blueprint improvements, not one-off kubectl folklore
