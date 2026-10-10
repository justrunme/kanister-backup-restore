#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${KANISTER_NAMESPACE:-kanister}"

kubectl apply -f "$ROOT/deploy/namespace.yaml"
kubectl apply -f "$ROOT/deploy/seaweedfs-profile.yaml"

kubectl -n "$NS" rollout status deploy/s3mock --timeout=180s
# Wait for s3mock to be ready
kubectl -n "$NS" wait --for=condition=complete job/s3mock-wait --timeout=180s || {
  # Job name is immutable if failed previously — delete and re-apply
  kubectl -n "$NS" delete job s3mock-wait --ignore-not-found
  kubectl apply -f "$ROOT/deploy/seaweedfs-profile.yaml"
  kubectl -n "$NS" wait --for=condition=complete job/s3mock-wait --timeout=180s
}

kubectl -n "$NS" get profile s3-profile
echo "S3Mock + Profile ready (bucket kanister-drills)"
