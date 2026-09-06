#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
kubectl apply -f "$ROOT/blueprints/postgres/blueprint.yaml"
kubectl apply -f "$ROOT/blueprints/generic-pvc/blueprint.yaml"
kubectl get blueprints
echo "blueprints applied"
