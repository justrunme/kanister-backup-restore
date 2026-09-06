#!/usr/bin/env bash
set -euo pipefail

NS="${DEMO_NAMESPACE:-demo-postgres}"
NAME="${DEMO_STATEFULSET:-postgres}"
BLUEPRINT="${BLUEPRINT:-postgres-app-aware}"
PROFILE_NS="${PROFILE_NS:-kanister}"
PROFILE_NAME="${PROFILE_NAME:-s3-profile}"
ACTIONSET="backup-${NAME}-$(date -u +%Y%m%d%H%M%S)"

kubectl apply -f examples/postgres-statefulset.yaml
kubectl -n "$NS" rollout status "statefulset/${NAME}" --timeout=180s

cat <<YAML | kubectl apply -f -
apiVersion: cr.kanister.io/v1alpha1
kind: ActionSet
metadata:
  name: ${ACTIONSET}
  namespace: ${PROFILE_NS}
  labels:
    app.kubernetes.io/name: kanister-backup-restore
    justrunme.com/phase: backup
spec:
  actions:
    - name: backup
      blueprint: ${BLUEPRINT}
      object:
        kind: StatefulSet
        name: ${NAME}
        namespace: ${NS}
      profile:
        name: ${PROFILE_NAME}
        namespace: ${PROFILE_NS}
YAML

echo "waiting for ActionSet/${ACTIONSET}..."
for _ in $(seq 1 60); do
  phase="$(kubectl -n "$PROFILE_NS" get "actionset/${ACTIONSET}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  echo "  state=${phase:-pending}"
  case "$phase" in
    complete) echo "backup-drill complete: ${ACTIONSET}"; exit 0 ;;
    failed) echo "backup-drill failed" >&2; kubectl -n "$PROFILE_NS" describe "actionset/${ACTIONSET}" >&2; exit 1 ;;
  esac
  sleep 5
done

echo "timed out waiting for ActionSet" >&2
exit 1
