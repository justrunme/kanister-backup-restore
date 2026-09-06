#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-profiles/s3-profile.yaml}"
if [[ ! -f "$PROFILE" ]]; then
  echo "Missing $PROFILE — copy profiles/s3-profile.example.yaml and fill credentials." >&2
  exit 1
fi

kubectl apply -f deploy/namespace.yaml
kubectl apply -f "$PROFILE"
kubectl -n kanister get profile,secret
echo "profile applied from $PROFILE"
