SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: help kind-up install-kanister minio demo-app apply-blueprints backup-drill validate-backup restore-drill \
	full-drill recovery-drill app-drill prove evidence failure-drill prune-backups test-evaluator apply-crds ci cron

help:
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

kind-up: ## Create Kind cluster
	chmod +x scripts/*.sh
	./scripts/kind-up.sh

install-kanister: ## Install Kanister operator (Helm)
	./scripts/install-kanister.sh

minio: ## MinIO + bucket + Kanister Profile
	./scripts/minio.sh

demo-app: ## Demo Postgres + seed data + linked S3 objects
	kubectl delete job -n demo-postgres postgres-seed --ignore-not-found
	kubectl apply -f examples/postgres-statefulset.yaml
	kubectl -n demo-postgres rollout status statefulset/postgres --timeout=180s
	kubectl -n demo-postgres wait --for=condition=complete job/postgres-seed --timeout=180s
	./scripts/seed-linked-app.sh

apply-blueprints: ## Apply Blueprint CRs
	./scripts/apply-blueprints.sh

apply-crds: ## Apply RecoveryContract / RecoveryDrill CRDs + example CRs
	kubectl apply -f deploy/crds/recoverycontract-crd.yaml
	kubectl apply -f deploy/crds/recoverydrill-crd.yaml
	kubectl wait --for=condition=Established crd/recoverycontracts.recovery.justrunme.com --timeout=60s
	kubectl wait --for=condition=Established crd/recoverydrills.recovery.justrunme.com --timeout=60s
	kubectl apply -f deploy/operator.yaml
	kubectl apply -f examples/recovery-contract.yaml

backup-drill: ## PROTECT — backup ActionSet
	./scripts/backup-drill.sh

validate-backup: ## VALIDATE — artifact integrity
	./scripts/validate-backup.sh

restore-drill: ## RESTORE — isolated namespace
	./scripts/restore-drill.sh

prove: ## Re-evaluate latest evidence against Recovery Contract
	./scripts/evaluate-contract.sh
	./scripts/export-metrics.sh

full-drill: ## Kind bring-up + multi-service Application Recovery Contract drill
	chmod +x scripts/*.sh
	./scripts/kind-up.sh
	./scripts/install-kanister.sh
	./scripts/minio.sh
	./scripts/apply-blueprints.sh
	$(MAKE) apply-crds
	$(MAKE) demo-app
	./scripts/break.sh reset
	./scripts/app-recovery-drill.sh
	./scripts/export-metrics.sh

app-drill: ## Application Recovery Contract (Postgres+S3 consistency)
	chmod +x scripts/*.sh
	./scripts/app-recovery-drill.sh
	./scripts/export-metrics.sh

recovery-drill: ## Postgres-only PROTECT → VALIDATE → RESTORE → PROVE
	chmod +x scripts/*.sh
	./scripts/recovery-drill.sh
	./scripts/export-metrics.sh

failure-drill: ## Inject failure then prove UNPROVED (SCENARIO=…)
	chmod +x scripts/*.sh
	./scripts/failure-drill.sh "$(SCENARIO)"

prune-backups: ## Keep N newest backups (BACKUP_RETAIN_N=5)
	./scripts/prune-backups.sh "$(BACKUP_RETAIN_N)"

test-evaluator: ## Pytest for evaluate_contract + prove_consistency
	cd scripts && python3 -m pytest -q test_evaluate_contract.py test_prove_consistency.py

evidence: ## Collect ActionSet evidence markdown
	./scripts/collect-evidence.sh

export-metrics: ## Export Prometheus metrics from latest evidence
	./scripts/export-metrics.sh

cron: ## Install weekly backup CronJob
	kubectl apply -f deploy/cronjob-backup-drill.yaml

prometheus-rules: ## Install PrometheusRule for alerting
	kubectl apply -f deploy/prometheus-rules.yaml

ci: ## Offline repository checks
	chmod +x scripts/*.sh
	./scripts/ci-check.sh

shellcheck: ## Run shellcheck on all scripts
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed" >&2; exit 1; }
	find scripts -name "*.sh" -type f -print0 | xargs -0 shellcheck -e SC1091

shfmt: ## Check shell formatting
	@command -v shfmt >/dev/null || { echo "shfmt not installed" >&2; exit 1; }
	shfmt -d -i 2 -ci -bn scripts/*.sh
