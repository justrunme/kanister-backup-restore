SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: help kind-up install-kanister minio demo-app apply-blueprints apply-profile backup-drill validate-backup restore-drill ci

help:
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

kind-up: ## Create Kind cluster
	chmod +x scripts/*.sh
	./scripts/kind-up.sh

install-kanister: ## Install Kanister operator via Helm
	./scripts/install-kanister.sh

minio: ## Deploy in-cluster MinIO for local drills
	./scripts/minio.sh

demo-app: ## Deploy example Postgres StatefulSet
	kubectl apply -f examples/postgres-statefulset.yaml
	kubectl -n demo-postgres rollout status statefulset/postgres --timeout=180s

apply-blueprints: ## Apply Kanister Blueprint CRs
	./scripts/apply-blueprints.sh

apply-profile: ## Apply object-store Profile (PROFILE=profiles/s3-profile.yaml)
	./scripts/apply-profile.sh

backup-drill: ## Run backup ActionSet against demo Postgres
	./scripts/backup-drill.sh

validate-backup: ## Validate latest backup ActionSet / artifacts
	./scripts/validate-backup.sh

restore-drill: ## Restore into an isolated drill namespace
	./scripts/restore-drill.sh

ci: ## Offline repository checks
	chmod +x scripts/*.sh
	./scripts/ci-check.sh
