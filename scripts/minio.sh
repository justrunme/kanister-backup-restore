#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${KANISTER_NAMESPACE:-kanister}"

kubectl apply -f "$ROOT/deploy/namespace.yaml"
kubectl apply -f "$ROOT/deploy/seaweedfs-profile.yaml"

kubectl -n "$NS" rollout status deploy/seaweedfs --timeout=180s

# Create the bucket from the runner (port-forward + SigV4).
# An in-cluster Job piping into `weed shell` never completes: the CLI is a REPL.
"$ROOT/scripts/s3-object.sh" ensure-bucket

kubectl -n "$NS" get profile s3-profile
echo "SeaweedFS S3 + Profile ready (bucket kanister-drills)"
