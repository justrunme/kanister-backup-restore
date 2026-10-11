#!/usr/bin/env bash
# Keep the N newest completed backup ActionSets; delete older ones (and their objects).
# Usage: prune-backups.sh [retain_n]
set -euo pipefail

PROFILE_NS="${PROFILE_NS:-kanister}"
PROFILE_NAME="${PROFILE_NAME:-s3-profile}"
NS="${DEMO_NAMESPACE:-demo-postgres}"
NAME="${DEMO_STATEFULSET:-postgres}"
BLUEPRINT="${BLUEPRINT:-postgres-app-aware}"
RETAIN="${1:-${BACKUP_RETAIN_N:-5}}"

mapfile -t ALL < <(
  kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[?(@.status.state=="complete")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
)

COUNT="${#ALL[@]}"
if [[ "$COUNT" -le "$RETAIN" ]]; then
  echo "prune: ${COUNT} backup(s) <= retain=${RETAIN}; nothing to delete"
  exit 0
fi

TO_DELETE=$((COUNT - RETAIN))
echo "prune: keeping ${RETAIN} newest of ${COUNT}; deleting ${TO_DELETE}"

for ((i = 0; i < TO_DELETE; i++)); do
  OLD="${ALL[$i]}"
  LOC="$(kubectl -n "$PROFILE_NS" get "actionset/${OLD}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupLocation}' 2>/dev/null || true)"
  SHA="$(kubectl -n "$PROFILE_NS" get "actionset/${OLD}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupSha256}' 2>/dev/null || true)"
  if [[ -z "$LOC" ]]; then
    echo "prune: ${OLD} has no backupLocation; deleting ActionSet only"
    kubectl -n "$PROFILE_NS" delete "actionset/${OLD}" --wait=false || true
    continue
  fi
  DEL_AS="delete-$(echo "$OLD" | tr '[:upper:]' '[:lower:]' | cut -c1-40)-$(date -u +%H%M%S)"
  cat <<YAML | kubectl apply -f -
apiVersion: cr.kanister.io/v1alpha1
kind: ActionSet
metadata:
  name: ${DEL_AS}
  namespace: ${PROFILE_NS}
  labels:
    app.kubernetes.io/name: kanister-backup-restore
    justrunme.com/phase: delete
spec:
  actions:
    - name: delete
      blueprint: ${BLUEPRINT}
      artifacts:
        cloudObject:
          keyValue:
            backupLocation: "${LOC}"
            backupSha256: "${SHA}"
            namespace: "${NS}"
            name: "${NAME}"
      object:
        kind: StatefulSet
        name: ${NAME}
        namespace: ${NS}
      profile:
        name: ${PROFILE_NAME}
        namespace: ${PROFILE_NS}
YAML
  for _ in $(seq 1 36); do
    st="$(kubectl -n "$PROFILE_NS" get "actionset/${DEL_AS}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
    case "$st" in
      complete | failed) break ;;
    esac
    sleep 5
  done
  kubectl -n "$PROFILE_NS" delete "actionset/${OLD}" --wait=false || true
  echo "prune: deleted object for ${OLD} via ${DEL_AS} (state=${st:-unknown})"
done
