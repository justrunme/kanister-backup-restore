#!/usr/bin/env bash
set -euo pipefail

PROFILE_NS="${PROFILE_NS:-kanister}"
SELECTOR="${SELECTOR:-justrunme.com/phase=backup}"

echo "validating latest backup ActionSet in ${PROFILE_NS} (${SELECTOR})"

NAME="$(kubectl -n "$PROFILE_NS" get actionsets -l "$SELECTOR" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
if [[ -z "${NAME}" ]]; then
  echo "no backup ActionSet found — run make backup-drill first" >&2
  exit 1
fi

STATE="$(kubectl -n "$PROFILE_NS" get "actionset/${NAME}" -o jsonpath='{.status.state}')"
echo "ActionSet/${NAME} state=${STATE}"

if [[ "$STATE" != "complete" ]]; then
  echo "backup ActionSet is not complete" >&2
  exit 1
fi

# Soft artifact checks: path/output presence when controller populated them
PATH_VAL="$(kubectl -n "$PROFILE_NS" get "actionset/${NAME}" -o jsonpath='{.status.actions[0].artifacts.backupInfo.keyValue.path}' 2>/dev/null || true)"
BACKUP_ID="$(kubectl -n "$PROFILE_NS" get "actionset/${NAME}" -o jsonpath='{.status.actions[0].artifacts.backupInfo.keyValue.backupId}' 2>/dev/null || true)"

if [[ -n "$PATH_VAL" ]]; then
  echo "artifact path: ${PATH_VAL}"
else
  echo "warning: artifact path empty — ensure blueprint outputs + Profile are wired"
fi
if [[ -n "$BACKUP_ID" ]]; then
  echo "backupId: ${BACKUP_ID}"
fi

echo "validate-backup ok (${NAME})"
