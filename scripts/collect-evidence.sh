#!/usr/bin/env bash
set -euo pipefail

PROFILE_NS="${PROFILE_NS:-kanister}"
OUT="${EVIDENCE_OUT:-./evidence-$(date -u +%Y%m%dT%H%M%SZ).md}"

{
  echo "# Kanister drill evidence"
  echo
  echo "- collected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- cluster: $(kubectl config current-context 2>/dev/null || echo unknown)"
  echo
  echo "## Blueprints"
  kubectl get blueprints -A -o wide 2>/dev/null || true
  echo
  echo "## Profile"
  kubectl -n "$PROFILE_NS" get profile -o wide 2>/dev/null || true
  echo
  echo "## ActionSets"
  kubectl -n "$PROFILE_NS" get actionsets -l app.kubernetes.io/name=kanister-backup-restore -o wide 2>/dev/null || true
  echo
  echo "## Latest backup artifact"
  LATEST="$(kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$LATEST" ]]; then
    echo "- actionset: ${LATEST}"
    kubectl -n "$PROFILE_NS" get "actionset/${LATEST}" -o jsonpath='- state: {.status.state}{"\n"}- backupLocation: {.status.actions[0].artifacts.cloudObject.keyValue.backupLocation}{"\n"}' 2>/dev/null || true
  else
    echo "- none"
  fi
  echo
  echo "## Restore drill namespaces"
  kubectl get ns -l justrunme.com/role=restore-drill -o wide 2>/dev/null || true
} | tee "$OUT"

echo "wrote ${OUT}"
