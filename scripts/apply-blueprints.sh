#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${KANISTER_NAMESPACE:-kanister}"

kubectl apply -n "$NS" -f "$ROOT/blueprints/postgres/blueprint.yaml"
kubectl apply -n "$NS" -f "$ROOT/blueprints/generic-pvc/blueprint.yaml"
kubectl -n "$NS" get blueprints
echo "blueprints applied in namespace ${NS}"
