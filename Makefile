SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: help kind-up install-kanister minio demo-app apply-blueprints backup-drill validate-backup restore-drill full-drill evidence ci cron

help:
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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

backup-drill: ## Backup ActionSet (pg_dump → MinIO)
	./scripts/backup-drill.sh

validate-backup: ## Validate latest backup artifact
	./scripts/validate-backup.sh

restore-drill: ## Restore into isolated namespace
	./scripts/restore-drill.sh

full-drill: ## End-to-end Kind drill + evidence
	chmod +x scripts/*.sh
	./scripts/full-drill.sh

evidence: ## Collect ActionSet / artifact evidence markdown
	./scripts/collect-evidence.sh

cron: ## Install weekly backup CronJob
	kubectl apply -f deploy/cronjob-backup-drill.yaml

ci: ## Offline repository checks
	chmod +x scripts/*.sh
	./scripts/ci-check.sh
