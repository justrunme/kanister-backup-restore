SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: help kind-up install-kanister minio demo-app apply-blueprints backup-drill validate-backup restore-drill full-drill evidence ci cron \
	recovery-drill confidence \
	break-backup break-secret break-schema break-rto break-reset \
	scenario-corrupt scenario-secret scenario-schema scenario-rto

help:
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

kind-up: ## Create Kind cluster
	chmod +x scripts/*.sh
	./scripts/kind-up.sh

install-kanister: ## Install Kanister operator (Helm)
	./scripts/install-kanister.sh

minio: ## MinIO + bucket + Kanister Profile
	./scripts/minio.sh

demo-app: ## Demo Postgres + seed data
	kubectl delete job -n demo-postgres postgres-seed --ignore-not-found
	kubectl apply -f examples/postgres-statefulset.yaml
	kubectl -n demo-postgres rollout status statefulset/postgres --timeout=180s
	kubectl -n demo-postgres wait --for=condition=complete job/postgres-seed --timeout=180s

apply-blueprints: ## Apply Blueprint CRs
	./scripts/apply-blueprints.sh

backup-drill: ## Protect: backup ActionSet
	./scripts/backup-drill.sh

validate-backup: ## Validate latest backup artifact
	./scripts/validate-backup.sh

restore-drill: ## Restore into isolated namespace
	./scripts/restore-drill.sh

recovery-drill: ## Protect → Break? → Restore → Prove → Confidence
	chmod +x scripts/*.sh
	./scripts/recovery-drill.sh

confidence: ## Recompute Recovery Confidence / SLO from latest evidence
	./scripts/compute-confidence.sh

full-drill: ## Kind bring-up + happy-path recovery confidence drill
	chmod +x scripts/*.sh
	./scripts/kind-up.sh
	./scripts/install-kanister.sh
	./scripts/minio.sh
	./scripts/apply-blueprints.sh
	$(MAKE) demo-app
	./scripts/break.sh reset
	./scripts/recovery-drill.sh

evidence: ## Collect ActionSet evidence markdown
	./scripts/collect-evidence.sh

## Failure scenarios (arm break, then recovery-drill)
break-backup: ## Corrupt artifact → VALIDATE fails
	./scripts/break.sh corrupt-artifact

break-secret: ## Wrong DB password → RESTORE fails
	./scripts/break.sh wrong-secret

break-schema: ## Drop recovery_markers → DATA VERIFY fails
	./scripts/break.sh schema-drift

break-rto: ## Sleep past RTO target → SLO BREACH
	./scripts/break.sh slow-restore

break-reset: ## Clear armed break scenario
	./scripts/break.sh reset

scenario-corrupt: break-backup recovery-drill ## Demo corrupt artifact confidence drop
scenario-secret: break-secret recovery-drill ## Demo wrong credentials
scenario-schema: break-schema recovery-drill ## Demo schema drift
scenario-rto: break-rto recovery-drill ## Demo RTO breach

cron: ## Install weekly backup CronJob
	kubectl apply -f deploy/cronjob-backup-drill.yaml

ci: ## Offline repository checks
	chmod +x scripts/*.sh
	./scripts/ci-check.sh
