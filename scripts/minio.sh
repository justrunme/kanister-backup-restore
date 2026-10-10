#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${KANISTER_NAMESPACE:-kanister}"

kubectl apply -f "$ROOT/deploy/namespace.yaml"
kubectl apply -f "$ROOT/deploy/seaweedfs-profile.yaml"

kubectl -n "$NS" rollout status deploy/seaweedfs --timeout=180s
if ! kubectl -n "$NS" wait --for=condition=complete job/seaweedfs-bootstrap-bucket --timeout=180s; then
  echo "bootstrap job failed; logs:" >&2
  kubectl -n "$NS" logs job/seaweedfs-bootstrap-bucket --tail=80 >&2 || true
  kubectl -n "$NS" logs deploy/seaweedfs --tail=40 >&2 || true
  kubectl -n "$NS" delete job seaweedfs-bootstrap-bucket --ignore-not-found
  kubectl apply -f "$ROOT/deploy/seaweedfs-profile.yaml"
  kubectl -n "$NS" wait --for=condition=complete job/seaweedfs-bootstrap-bucket --timeout=180s
fi
kubectl -n "$NS" logs job/seaweedfs-bootstrap-bucket --tail=40 || true

kubectl -n "$NS" get profile s3-profile
echo "SeaweedFS S3 + Profile ready (bucket kanister-drills)"
