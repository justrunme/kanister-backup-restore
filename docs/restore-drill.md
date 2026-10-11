# Restore drill runbook

## Goal

Prove restore works **before** an incident — on Kind or a non-prod cluster.

## Pass criteria

- [ ] Unique proof marker written to the source DB immediately before backup
- [ ] Backup ActionSet `complete` with unique object key + recorded `sha256`
- [ ] Validate ActionSet `complete` (`sha256` match + scratch SQL restore)
- [ ] Restore ActionSet `complete` into an **unseeded** `restore-drill-*` namespace
- [ ] Exact marker row found; row count / checksum match source
- [ ] Evaluator exits 0 (`PROVED`); evidence under `.evidence/`

## Fast path

```bash
make full-drill
```

## Manual path

```bash
make kind-up install-kanister minio apply-blueprints
make demo-app
make backup-drill
make validate-backup
make restore-drill
make evidence
```

## Negative proof

```bash
make failure-drill SCENARIO=noop-restore
# expect UNPROVED reason=data_verification
```

## Fail criteria

- ActionSet `failed` / stuck `running`
- Empty `backupLocation` or missing `backupSha256`
- Skipping validate “because backup looked fine”
- Restoring into the production namespace
- Seeded restore DB that already contains markers (false positive)
- Evaluator exits 0 on UNPROVED

## Cleanup

```bash
kubectl delete ns -l justrunme.com/role=restore-drill
kubectl -n kanister delete actionsets -l app.kubernetes.io/name=kanister-backup-restore
```
