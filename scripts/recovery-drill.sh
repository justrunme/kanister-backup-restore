#!/usr/bin/env bash
# Recovery Contract drill: PROTECT → VALIDATE → RESTORE → PROVE
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_NS="${PROFILE_NS:-kanister}"
PROFILE_NAME="${PROFILE_NAME:-minio-profile}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/.evidence}"
STATE_FILE="$EVIDENCE_DIR/active-break.env"
SEQ_FILE="$EVIDENCE_DIR/drill-seq"
mkdir -p "$EVIDENCE_DIR"

SCENARIO="happy-path"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  SCENARIO="${BREAK_SCENARIO:-happy-path}"
fi

checks_backup=false
checks_artifact=false
checks_restore=false
checks_health=false
checks_data=false
checks_rto=false
checks_fresh=true
RTO_SECONDS=""
RPO_SECONDS=""
DRILL_NS=""
BACKUP_AS=""
RESTORE_AS=""
BACKUP_LOC=""
BLOCKED_AT=""

now_epoch() { date -u +%s; }

DRILL_ID=1
if [[ -f "$SEQ_FILE" ]]; then
  DRILL_ID=$(( $(cat "$SEQ_FILE") + 1 ))
fi
echo "$DRILL_ID" > "$SEQ_FILE"

echo "== Recovery Contract drill #${DRILL_ID} · scenario=${SCENARIO} =="
echo "== PROTECT → VALIDATE → RESTORE → PROVE =="

emit_evidence() {
  python3 - "$EVIDENCE_DIR" "$DRILL_ID" "$SCENARIO" "$BLOCKED_AT" \
    "$BACKUP_AS" "$RESTORE_AS" "$DRILL_NS" "$BACKUP_LOC" \
    "$checks_backup" "$checks_artifact" "$checks_restore" \
    "$checks_health" "$checks_data" "$checks_rto" "$checks_fresh" \
    "${RPO_SECONDS}" "${RTO_SECONDS}" <<'PY'
import json, sys, pathlib
from datetime import datetime, timezone

(
  out_dir, drill_id, scenario, blocked, backup_as, restore_as, drill_ns, backup_loc,
  c_backup, c_art, c_rest, c_health, c_data, c_rto, c_fresh, rpo, rto,
) = sys.argv[1:]

def b(x):
  return str(x).lower() in ("true", "1", "yes")

def ni(x):
  return int(x) if x not in ("", "null", "None") else None

ev = {
  "drill_id": int(drill_id),
  "scenario": scenario,
  "blocked_at": blocked or None,
  "backup_actionset": backup_as or None,
  "restore_actionset": restore_as or None,
  "drill_namespace": drill_ns or None,
  "backup_location": backup_loc or None,
  "collected_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "checks": {
    "backup": b(c_backup),
    "artifact_integrity": b(c_art),
    "restore_completed": b(c_rest),
    "application_health": b(c_health),
    "data_verification": b(c_data),
    "rto_within_target": b(c_rto),
    "evidence_fresh": b(c_fresh),
  },
  "metrics": {
    "rpo_seconds": ni(rpo),
    "rto_seconds": ni(rto),
    "evidence_age_hours": 0,
    "drill_id": int(drill_id),
  },
}
out = pathlib.Path(out_dir)
latest = out / "drill-latest.json"
latest.write_text(json.dumps(ev, indent=2) + "\n")
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
(out / f"drill-{stamp}.json").write_text(latest.read_text())
print(f"wrote {latest}")
PY
  "$ROOT/scripts/evaluate-contract.sh" "$EVIDENCE_DIR/drill-latest.json" || true
  if [[ "$SCENARIO" != "happy-path" ]]; then
    rm -f "$STATE_FILE"
    echo "-- failure scenario state cleared"
  fi
}

# --- PROTECT ---
BACKUP_AS="$(kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
BACKUP_STATE=""
if [[ -n "$BACKUP_AS" ]]; then
  BACKUP_STATE="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
fi
if [[ "$BACKUP_STATE" != "complete" ]]; then
  echo "-- protect: creating backup"
  "$ROOT/scripts/backup-drill.sh"
  BACKUP_AS="$(kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
  BACKUP_STATE="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.state}' 2>/dev/null || true)"
fi

if [[ "$BACKUP_STATE" == "complete" ]]; then
  checks_backup=true
else
  BLOCKED_AT="protect"
fi

BACKUP_LOC="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupLocation}' 2>/dev/null || true)"
BACKUP_CREATED="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
if [[ -n "$BACKUP_CREATED" ]]; then
  if BACKUP_EPOCH=$(date -u -d "$BACKUP_CREATED" +%s 2>/dev/null); then
    :
  else
    BACKUP_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${BACKUP_CREATED}" +%s 2>/dev/null || true)
  fi
  if [[ -n "${BACKUP_EPOCH:-}" ]]; then
    RPO_SECONDS=$(( $(now_epoch) - BACKUP_EPOCH ))
  fi
fi
echo "-- protect: backup=${BACKUP_AS} ($([[ $checks_backup == true ]] && echo PASS || echo FAIL))"

if [[ "$checks_backup" != true ]]; then
  emit_evidence
  exit 0
fi

# --- VALIDATE ---
echo "-- validate artifact"
set +e
FROM_ACTIONSET="$BACKUP_AS" ACTION=validate "$ROOT/scripts/run-action.sh"
VAL_RC=$?
set -e
if [[ $VAL_RC -eq 0 ]]; then
  checks_artifact=true
  echo "   artifact_integrity PASS"
else
  BLOCKED_AT="validate"
  echo "   artifact_integrity FAIL"
fi

if [[ "$checks_artifact" != true ]]; then
  RTO_SECONDS=0
  emit_evidence
  exit 0
fi

# --- RESTORE ---
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
  echo "   isolated_restore PASS (rto=${RTO_SECONDS}s)"
else
  BLOCKED_AT="${BLOCKED_AT:-restore}"
  echo "   isolated_restore FAIL"
fi

# --- PROVE ---
if [[ "$checks_restore" == true ]]; then
  if kubectl -n "$DRILL_NS" exec sts/postgres -- pg_isready -U postgres >/dev/null 2>&1; then
    checks_health=true
    echo "   application_ready PASS"
  else
    BLOCKED_AT="${BLOCKED_AT:-verify}"
    echo "   application_ready FAIL"
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
    BLOCKED_AT="${BLOCKED_AT:-verify}"
    echo "   data_verification FAIL"
  fi
fi

RTO_TARGET=60
if [[ -n "$RTO_SECONDS" && "$RTO_SECONDS" -le "$RTO_TARGET" && "$checks_restore" == true ]]; then
  checks_rto=true
else
  checks_rto=false
  if [[ "$checks_restore" == true && "$SCENARIO" == "slow-restore" ]]; then
    BLOCKED_AT="${BLOCKED_AT:-rto}"
  fi
fi
echo "   rto $([[ $checks_rto == true ]] && echo PASS || echo FAIL) (${RTO_SECONDS}s / ${RTO_TARGET}s)"
checks_fresh=true

emit_evidence
"$ROOT/scripts/collect-evidence.sh" || true
