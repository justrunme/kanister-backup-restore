#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_NS="${PROFILE_NS:-kanister}"
PROFILE_NAME="${PROFILE_NAME:-minio-profile}"
NS="${DEMO_NAMESPACE:-demo-postgres}"
NAME="${DEMO_STATEFULSET:-postgres}"
BLUEPRINT="${BLUEPRINT:-postgres-app-aware}"
ACTION="${ACTION:-backup}" # backup | validate
ACTIONSET="${ACTION}-${NAME}-$(date -u +%Y%m%d%H%M%S)"

wait_actionset() {
  local ns="$1" name="$2"
  for _ in $(seq 1 90); do
    local phase
    phase="$(kubectl -n "$ns" get "actionset/${name}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
    echo "  ${name}: ${phase:-pending}"
    case "$phase" in
      complete) return 0 ;;
      failed)
        kubectl -n "$ns" describe "actionset/${name}" >&2
        return 1
        ;;
    esac
    sleep 5
  done
  echo "timed out waiting for ActionSet/${name}" >&2
  return 1
}

kubectl apply -f "$ROOT/examples/postgres-statefulset.yaml"
kubectl -n "$NS" rollout status "statefulset/${NAME}" --timeout=180s
kubectl -n "$NS" wait --for=condition=complete job/postgres-seed --timeout=180s || true

ARTIFACTS_BLOCK=""
if [[ "$ACTION" == "validate" || "$ACTION" == "restore" ]]; then
  FROM="${FROM_ACTIONSET:-}"
  if [[ -z "$FROM" ]]; then
    FROM="$(kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
  fi
  if [[ -z "$FROM" ]]; then
    echo "no backup ActionSet found — run backup first" >&2
    exit 1
  fi
  LOC="$(kubectl -n "$PROFILE_NS" get "actionset/${FROM}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupLocation}')"
  if [[ -z "$LOC" ]]; then
    # fallback older path styles
    LOC="$(kubectl -n "$PROFILE_NS" get "actionset/${FROM}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.KeyValue.backupLocation}')"
  fi
  if [[ -z "$LOC" ]]; then
    echo "backup ActionSet ${FROM} has empty backupLocation" >&2
    kubectl -n "$PROFILE_NS" get "actionset/${FROM}" -o yaml >&2
    exit 1
  fi
  echo "using artifacts from ${FROM}: ${LOC}"
  ARTIFACTS_BLOCK=$(cat <<EOF
      artifacts:
        cloudObject:
          keyValue:
            backupLocation: "${LOC}"
            namespace: "${NS}"
            name: "${NAME}"
EOF
)
fi

cat <<YAML | kubectl apply -f -
apiVersion: cr.kanister.io/v1alpha1
kind: ActionSet
metadata:
  name: ${ACTIONSET}
  namespace: ${PROFILE_NS}
  labels:
    app.kubernetes.io/name: kanister-backup-restore
    justrunme.com/phase: ${ACTION}
spec:
  actions:
    - name: ${ACTION}
      blueprint: ${BLUEPRINT}
${ARTIFACTS_BLOCK}
      object:
        kind: StatefulSet
        name: ${NAME}
        namespace: ${NS}
      profile:
        name: ${PROFILE_NAME}
        namespace: ${PROFILE_NS}
YAML

wait_actionset "$PROFILE_NS" "$ACTIONSET"
echo "${ACTION} complete: ${ACTIONSET}"
if [[ "$ACTION" == "backup" ]]; then
  kubectl -n "$PROFILE_NS" get "actionset/${ACTIONSET}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupLocation}{"\n"}'
fi
