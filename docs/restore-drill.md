# Restore drill runbook

## Goal

Prove restore works **before** an incident — on Kind or a non-prod cluster.

## Pass criteria

- [ ] Backup ActionSet `complete`
- [ ] Validate ActionSet `complete` (`gzip -t` + SQL head)
- [ ] Restore ActionSet `complete` in `restore-drill-*`
- [ ] `recovery_markers` rows visible in drill namespace
- [ ] Evidence markdown captured

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

## Fail criteria

- ActionSet `failed` / stuck `running`
- Empty `backupLocation`
- Skipping validate “because backup looked fine”
- Restoring into the production namespace

## Cleanup

```bash
kubectl delete ns -l justrunme.com/role=restore-drill
kubectl -n kanister delete actionsets -l app.kubernetes.io/name=kanister-backup-restore
```
