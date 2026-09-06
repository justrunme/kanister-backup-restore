#!/usr/bin/env bash
# Continuous Recovery Confidence drill:
# Protect → (optional Break) → Restore → Prove → Confidence / SLO
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_NS="${PROFILE_NS:-kanister}"
PROFILE_NAME="${PROFILE_NAME:-minio-profile}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/.evidence}"
STATE_FILE="$EVIDENCE_DIR/active-break.env"
mkdir -p "$EVIDENCE_DIR"

SCENARIO="happy-path"
EXPECTED_BLOCKED_AT=""
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  SCENARIO="${BREAK_SCENARIO:-happy-path}"
  EXPECTED_BLOCKED_AT="${EXPECTED_BLOCKED_AT:-}"
fi

checks_artifact=false
checks_restore=false
checks_health=false
checks_data=false
checks_rto=false
checks_fresh=true
RTO_SECONDS=""
DRILL_NS=""
BACKUP_AS=""
RESTORE_AS=""
BACKUP_LOC=""
BLOCKED_AT=""

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }

echo "== Recovery Confidence drill · scenario=${SCENARIO} =="

# 1) Protect — ensure backup exists (reuse latest complete or create)
BACKUP_AS="$(kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
BACKUP_STATE=""
if [[ -n "$BACKUP_AS" ]]; then
  BACKUP_STATE="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
fi
if [[ "$BACKUP_STATE" != "complete" ]]; then
  echo "-- protect: creating backup"
  "$ROOT/scripts/backup-drill.sh"
  BACKUP_AS="$(kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
fi
BACKUP_LOC="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupLocation}')"
echo "-- protect: backup=${BACKUP_AS} loc=${BACKUP_LOC}"

# 2) Validate artifact (unless we expect validate block — still run to capture failure)
echo "-- validate artifact"
set +e
FROM_ACTIONSET="$BACKUP_AS" ACTION=validate "$ROOT/scripts/run-action.sh"
VAL_RC=$?
set -e
if [[ $VAL_RC -eq 0 ]]; then
  checks_artifact=true
  echo "   artifact_integrity PASS"
else
  checks_artifact=false
  BLOCKED_AT="validate"
  echo "   artifact_integrity FAIL"
  if [[ "$SCENARIO" == "corrupt-artifact" ]]; then
    echo "   expected failure for corrupt-artifact"
  fi
fi

# Early exit for corrupt path — cannot restore safely
if [[ "$checks_artifact" != true ]]; then
  RTO_SECONDS=0
  checks_rto=false
  checks_fresh=true
  # write evidence + score
  cat > "$EVIDENCE_DIR/drill-latest.json" <<JSON
{
  "scenario": "${SCENARIO}",
  "blocked_at": "${BLOCKED_AT}",
  "backup_actionset": "${BACKUP_AS}",
  "restore_actionset": null,
  "drill_namespace": null,
  "backup_location": "${BACKUP_LOC}",
  "collected_at": "$(ts)",
  "checks": {
    "artifact_integrity": false,
    "restore_completed": false,
    "application_health": false,
    "data_verification": false,
    "rto_within_target": false,
    "evidence_fresh": true
  },
  "metrics": {
    "rto_seconds": 0,
    "evidence_age_hours": 0
  }
}
JSON
  cp "$EVIDENCE_DIR/drill-latest.json" "$EVIDENCE_DIR/drill-$(date -u +%Y%m%dT%H%M%SZ).json"
  "$ROOT/scripts/compute-confidence.sh" "$EVIDENCE_DIR/drill-latest.json" || true
  exit 0
fi

# 3) Restore into isolated namespace (apply break hooks)
DRILL_NS="restore-drill-$(date -u +%Y%m%d%H%M%S)"
RESTORE_AS="restore-postgres-$(date -u +%Y%m%d%H%M%S)"
echo "-- restore into ${DRILL_NS}"

START=$(now_epoch)
sed "s/name: demo-postgres/name: ${DRILL_NS}/g" "$ROOT/examples/postgres-statefulset.yaml" \
  | sed "s/postgres-seed/postgres-seed-${DRILL_NS}/g" \
  | kubectl apply -f -
kubectl -n "$DRILL_NS" rollout status statefulset/postgres --timeout=180s

if [[ "$SCENARIO" == "wrong-secret" ]]; then
  echo "   injecting wrong-secret"
  kubectl -n "$DRILL_NS" create secret generic postgres-credentials \
    --from-literal=POSTGRES_USER=postgres \
    --from-literal=POSTGRES_PASSWORD="${BREAK_BAD_PASSWORD:-wrong}" \
    --from-literal=POSTGRES_DB=app \
    --dry-run=client -o yaml | kubectl apply -f -
fi

if [[ "$SCENARIO" == "slow-restore" ]]; then
  echo "   injecting slow-restore sleep ${BREAK_RTO_SLEEP_SECONDS:-75}s"
  sleep "${BREAK_RTO_SLEEP_SECONDS:-75}"
fi

cat <<YAML | kubectl apply -f -
apiVersion: cr.kanister.io/v1alpha1
kind: ActionSet
metadata:
  name: ${RESTORE_AS}
  namespace: ${PROFILE_NS}
  labels:
    app.kubernetes.io/name: kanister-backup-restore
    justrunme.com/phase: restore
    justrunme.com/scenario: ${SCENARIO}
spec:
  actions:
    - name: restore
      blueprint: postgres-app-aware
      artifacts:
        cloudObject:
          keyValue:
            backupLocation: "${BACKUP_LOC}"
            namespace: "${DRILL_NS}"
            name: postgres
      object:
        kind: StatefulSet
        name: postgres
        namespace: ${DRILL_NS}
      profile:
        name: ${PROFILE_NAME}
        namespace: ${PROFILE_NS}
YAML

RESTORE_OK=false
for _ in $(seq 1 90); do
  st="$(kubectl -n "$PROFILE_NS" get "actionset/${RESTORE_AS}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
  case "$st" in
    complete) RESTORE_OK=true; break ;;
    failed) break ;;
  esac
  sleep 5
done
END=$(now_epoch)
RTO_SECONDS=$((END - START))

if [[ "$RESTORE_OK" == true ]]; then
  checks_restore=true
  echo "   restore_completed PASS (rto=${RTO_SECONDS}s)"
else
  checks_restore=false
  BLOCKED_AT="${BLOCKED_AT:-restore}"
  echo "   restore_completed FAIL"
fi

# 4) Verify application + data
if [[ "$checks_restore" == true ]]; then
  if kubectl -n "$DRILL_NS" exec sts/postgres -- pg_isready -U postgres >/dev/null 2>&1; then
    checks_health=true
    echo "   application_health PASS"
  else
    checks_health=false
    BLOCKED_AT="${BLOCKED_AT:-verify}"
    echo "   application_health FAIL"
  fi

  if [[ "$SCENARIO" == "schema-drift" ]]; then
    echo "   injecting schema-drift (drop recovery_markers)"
    kubectl -n "$DRILL_NS" exec sts/postgres -- \
      psql -U postgres -d app -c 'DROP TABLE IF EXISTS recovery_markers;' >/dev/null || true
  fi

  if kubectl -n "$DRILL_NS" exec sts/postgres -- \
      psql -U postgres -d app -tAc "SELECT COUNT(*) FROM recovery_markers" 2>/dev/null | grep -Eq '^[1-9]'; then
    checks_data=true
    echo "   data_verification PASS"
  else
    checks_data=false
    BLOCKED_AT="${BLOCKED_AT:-verify}"
    echo "   data_verification FAIL"
  fi
fi

# RTO check
RTO_TARGET=60
if [[ -n "$RTO_SECONDS" && "$RTO_SECONDS" -le "$RTO_TARGET" && "$checks_restore" == true ]]; then
  checks_rto=true
else
  checks_rto=false
  if [[ "$checks_restore" == true && "$SCENARIO" == "slow-restore" ]]; then
    BLOCKED_AT="${BLOCKED_AT:-rto}"
  fi
fi
echo "   rto_within_target $([[ $checks_rto == true ]] && echo PASS || echo FAIL) (${RTO_SECONDS}s / ${RTO_TARGET}s)"

# Evidence freshness: this prove is now
checks_fresh=true

cat > "$EVIDENCE_DIR/drill-latest.json" <<JSON
{
  "scenario": "${SCENARIO}",
  "blocked_at": "${BLOCKED_AT}",
  "backup_actionset": "${BACKUP_AS}",
  "restore_actionset": "${RESTORE_AS}",
  "drill_namespace": "${DRILL_NS}",
  "backup_location": "${BACKUP_LOC}",
  "collected_at": "$(ts)",
  "checks": {
    "artifact_integrity": $([[ $checks_artifact == true ]] && echo true || echo false),
    "restore_completed": $([[ $checks_restore == true ]] && echo true || echo false),
    "application_health": $([[ $checks_health == true ]] && echo true || echo false),
    "data_verification": $([[ $checks_data == true ]] && echo true || echo false),
    "rto_within_target": $([[ $checks_rto == true ]] && echo true || echo false),
    "evidence_fresh": $([[ $checks_fresh == true ]] && echo true || echo false)
  },
  "metrics": {
    "rto_seconds": ${RTO_SECONDS:-null},
    "evidence_age_hours": 0
  }
}
JSON
cp "$EVIDENCE_DIR/drill-latest.json" "$EVIDENCE_DIR/drill-$(date -u +%Y%m%dT%H%M%SZ).json"

"$ROOT/scripts/compute-confidence.sh" "$EVIDENCE_DIR/drill-latest.json" || true
"$ROOT/scripts/collect-evidence.sh" || true

# Clear one-shot break state after drill (except user may want to re-run)
if [[ "$SCENARIO" != "happy-path" ]]; then
  rm -f "$STATE_FILE"
  echo "-- break state cleared after drill"
fi
