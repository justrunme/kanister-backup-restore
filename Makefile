SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: help kind-up install-kanister minio demo-app apply-blueprints backup-drill validate-backup restore-drill \
	full-drill recovery-drill prove evidence failure-drill ci cron

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

backup-drill: ## PROTECT — backup ActionSet
	./scripts/backup-drill.sh

validate-backup: ## VALIDATE — artifact integrity
	./scripts/validate-backup.sh

restore-drill: ## RESTORE — isolated namespace
	./scripts/restore-drill.sh

recovery-drill: ## PROTECT → VALIDATE → RESTORE → PROVE
	chmod +x scripts/*.sh
	./scripts/recovery-drill.sh

prove: ## Re-evaluate latest evidence against Recovery Contract
	./scripts/evaluate-contract.sh

full-drill: ## Kind bring-up + happy-path Recovery Contract drill
	chmod +x scripts/*.sh
	./scripts/kind-up.sh
	./scripts/install-kanister.sh
	./scripts/minio.sh
	./scripts/apply-blueprints.sh
	$(MAKE) demo-app
	./scripts/break.sh reset
	./scripts/recovery-drill.sh

failure-drill: ## Inject failure then prove UNPROVED (SCENARIO=corrupt-artifact|…)
	chmod +x scripts/*.sh
	./scripts/failure-drill.sh "$(SCENARIO)"

evidence: ## Collect ActionSet evidence markdown
	./scripts/collect-evidence.sh

cron: ## Install weekly backup CronJob
	kubectl apply -f deploy/cronjob-backup-drill.yaml

ci: ## Offline repository checks
	chmod +x scripts/*.sh
	./scripts/ci-check.sh
