#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"

KANISTER_VERSION="${KANISTER_VERSION:-0.118.0}"
NS="${KANISTER_NAMESPACE:-kanister}"

kubectl apply -f "$ROOT/deploy/namespace.yaml"

if ! helm repo list 2>/dev/null | grep -q kanister; then
  helm repo add kanister https://charts.kanister.io/
fi
helm repo update kanister >/dev/null

helm upgrade --install kanister-operator kanister/kanister-operator \
  --namespace "$NS" \
  --create-namespace \
  --version "$KANISTER_VERSION" \
  --wait

kubectl apply -f "$ROOT/deploy/kanister-rbac.yaml"
kubectl -n "$NS" rollout status deploy/kanister-operator --timeout=180s
echo "Kanister operator ${KANISTER_VERSION} ready in namespace ${NS}"
