#!/usr/bin/env bash
set -euo pipefail

KANISTER_VERSION="${KANISTER_VERSION:-0.118.0}"
NS="${KANISTER_NAMESPACE:-kanister}"

kubectl apply -f deploy/namespace.yaml

if ! helm repo list 2>/dev/null | grep -q kanister; then
  helm repo add kanister https://charts.kanister.io/
fi
helm repo update kanister >/dev/null

helm upgrade --install kanister-operator kanister/kanister-operator \
  --namespace "$NS" \
  --create-namespace \
  --version "$KANISTER_VERSION" \
  --wait

kubectl -n "$NS" rollout status deploy/kanister-operator --timeout=180s
echo "Kanister operator ${KANISTER_VERSION} ready in namespace ${NS}"
