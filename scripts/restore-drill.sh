#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_NS="${PROFILE_NS:-kanister}"
PROFILE_NAME="${PROFILE_NAME:-minio-profile}"
BLUEPRINT="${BLUEPRINT:-postgres-app-aware}"
NAME="${DEMO_STATEFULSET:-postgres}"
DRILL_NS="restore-drill-$(date -u +%Y%m%d%H%M%S)"
ACTIONSET="restore-${NAME}-$(date -u +%Y%m%d%H%M%S)"

FROM="${FROM_ACTIONSET:-}"
if [[ -z "$FROM" ]]; then
  FROM="$(kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
fi
[[ -n "$FROM" ]] || { echo "no backup ActionSet" >&2; exit 1; }

LOC="$(kubectl -n "$PROFILE_NS" get "actionset/${FROM}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupLocation}')"
[[ -n "$LOC" ]] || { echo "empty backupLocation on ${FROM}" >&2; exit 1; }

echo "restore from ${FROM} -> ns ${DRILL_NS}"
echo "artifact: ${LOC}"

# Fresh namespace + Postgres (same credentials secret shape the blueprint expects)
sed "s/name: demo-postgres/name: ${DRILL_NS}/g" "$ROOT/examples/postgres-statefulset.yaml" \
  | sed "s/postgres-seed/postgres-seed-${DRILL_NS}/g" \
  | kubectl apply -f -

kubectl -n "$DRILL_NS" rollout status "statefulset/${NAME}" --timeout=180s

cat <<YAML | kubectl apply -f -
apiVersion: cr.kanister.io/v1alpha1
kind: ActionSet
metadata:
  name: ${ACTIONSET}
  namespace: ${PROFILE_NS}
  labels:
    app.kubernetes.io/name: kanister-backup-restore
    justrunme.com/phase: restore
spec:
  actions:
    - name: restore
      blueprint: ${BLUEPRINT}
      artifacts:
        cloudObject:
          keyValue:
            backupLocation: "${LOC}"
            namespace: "${DRILL_NS}"
            name: "${NAME}"
      object:
        kind: StatefulSet
        name: ${NAME}
        namespace: ${DRILL_NS}
      profile:
        name: ${PROFILE_NAME}
        namespace: ${PROFILE_NS}
YAML

for _ in $(seq 1 90); do
  phase="$(kubectl -n "$PROFILE_NS" get "actionset/${ACTIONSET}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  echo "  state=${phase:-pending}"
  case "$phase" in
    complete)
      echo "restore-drill complete in ${DRILL_NS}"
      kubectl -n "$DRILL_NS" exec "sts/${NAME}" -- \
        psql -U postgres -d app -c 'SELECT id, note, created_at FROM recovery_markers ORDER BY id DESC LIMIT 5;' || true
      exit 0
      ;;
    failed)
      kubectl -n "$PROFILE_NS" describe "actionset/${ACTIONSET}" >&2
      exit 1
      ;;
  esac
  sleep 5
done
echo "timed out" >&2
exit 1
