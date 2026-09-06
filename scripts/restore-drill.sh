#!/usr/bin/env bash
set -euo pipefail

NAME="${DEMO_STATEFULSET:-postgres}"
BLUEPRINT="${BLUEPRINT:-postgres-app-aware}"
PROFILE_NS="${PROFILE_NS:-kanister}"
PROFILE_NAME="${PROFILE_NAME:-s3-profile}"
DRILL_NS="restore-drill-$(date -u +%Y%m%d%H%M%S)"
ACTIONSET="restore-${NAME}-$(date -u +%Y%m%d%H%M%S)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

kubectl create namespace "$DRILL_NS"
kubectl label namespace "$DRILL_NS" \
  app.kubernetes.io/name=kanister-backup-restore \
  justrunme.com/role=restore-drill

# Deploy a fresh Postgres into the drill namespace (isolated from demo-postgres)
sed "s/name: demo-postgres/name: ${DRILL_NS}/" "$ROOT/examples/postgres-statefulset.yaml" | kubectl apply -f -
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
      object:
        kind: StatefulSet
        name: ${NAME}
        namespace: ${DRILL_NS}
      profile:
        name: ${PROFILE_NAME}
        namespace: ${PROFILE_NS}
YAML

echo "restore drill namespace: ${DRILL_NS}"
echo "ActionSet: ${ACTIONSET}"

for _ in $(seq 1 60); do
  phase="$(kubectl -n "$PROFILE_NS" get "actionset/${ACTIONSET}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  echo "  state=${phase:-pending}"
  case "$phase" in
    complete) echo "restore-drill complete"; exit 0 ;;
    failed) echo "restore-drill failed" >&2; kubectl -n "$PROFILE_NS" describe "actionset/${ACTIONSET}" >&2; exit 1 ;;
  esac
  sleep 5
done

echo "timed out" >&2
exit 1
