#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kanister-drill}"
K8S_VERSION="${K8S_VERSION:-v1.30.0}"

if ! command -v kind >/dev/null; then
  echo "kind is required" >&2
  exit 1
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "kind cluster '$CLUSTER_NAME' already exists"
else
  kind create cluster --name "$CLUSTER_NAME" --image "kindest/node:${K8S_VERSION}"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"
kubectl apply -f deploy/namespace.yaml
echo "kind-up complete"
