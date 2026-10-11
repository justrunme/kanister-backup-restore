#!/usr/bin/env bash
# Recovery Contract drill: PROTECT → VALIDATE → RESTORE → PROVE
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_NS="${PROFILE_NS:-kanister}"
PROFILE_NAME="${PROFILE_NAME:-s3-profile}"
DEMO_NS="${DEMO_NAMESPACE:-demo-postgres}"
DEMO_STS="${DEMO_STATEFULSET:-postgres}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/.evidence}"
STATE_FILE="$EVIDENCE_DIR/active-break.env"
SEQ_FILE="$EVIDENCE_DIR/drill-seq"
MARKER_FILE="$EVIDENCE_DIR/active-marker.env"
CONTRACT_JSON="$ROOT/config/recovery-contract.json"
BACKUP_RETAIN_N="${BACKUP_RETAIN_N:-5}"
mkdir -p "$EVIDENCE_DIR"

SCENARIO="happy-path"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  SCENARIO="${BREAK_SCENARIO:-happy-path}"
fi

RTO_TARGET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["contract"]["rto_seconds_max"])' "$CONTRACT_JSON")"

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
BACKUP_SHA=""
BACKUP_TS=""
BLOCKED_AT=""
MARKER_UUID=""
MARKER_NOTE=""
MARKER_TS=""
SOURCE_ROW_COUNT=""
SOURCE_CHECKSUM=""
SOURCE_SCHEMA_HASH=""
EVAL_RC=0

now_epoch() { date -u +%s; }

iso_to_epoch() {
  local ts="$1"
  if date -u -d "$ts" +%s 2>/dev/null; then
    return 0
  fi
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${ts}" +%s 2>/dev/null || true
}

DRILL_ID=1
if [[ -f "$SEQ_FILE" ]]; then
  DRILL_ID=$(($(cat "$SEQ_FILE") + 1))
fi
echo "$DRILL_ID" >"$SEQ_FILE"

echo "== Recovery Contract drill #${DRILL_ID} · scenario=${SCENARIO} =="
echo "== PROTECT → VALIDATE → RESTORE → PROVE =="

cleanup_old_drills() {
  # Keep the current drill namespace; delete older restore-drill namespaces.
  local ns
  while read -r ns; do
    [[ -n "$ns" ]] || continue
    if [[ -n "${DRILL_NS}" && "$ns" == "$DRILL_NS" ]]; then
      continue
    fi
    echo "-- cleanup: deleting namespace ${ns}"
    kubectl delete ns "$ns" --wait=false --ignore-not-found >/dev/null 2>&1 || true
  done < <(kubectl get ns -l justrunme.com/role=restore-drill -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
}

insert_proof_marker() {
  MARKER_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
  MARKER_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  MARKER_NOTE="drill-${DRILL_ID}-${MARKER_UUID}-${MARKER_TS}"
  echo "-- protect: writing proof marker ${MARKER_NOTE}"
  # Ensure schema + insert marker (quiet: no CREATE/INSERT command tags on stdout).
  kubectl -n "$DEMO_NS" exec "sts/${DEMO_STS}" -- \
    psql -U postgres -d app -v ON_ERROR_STOP=1 -q -c "
CREATE TABLE IF NOT EXISTS recovery_markers (
  id SERIAL PRIMARY KEY,
  note TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO recovery_markers (note, created_at)
VALUES ('${MARKER_NOTE}', TIMESTAMPTZ '${MARKER_TS}');
" >/dev/null

  # Separate tuples-only SELECT so stdout is only "rows:checksum".
  local stats
  stats="$(kubectl -n "$DEMO_NS" exec "sts/${DEMO_STS}" -- \
    psql -U postgres -d app -v ON_ERROR_STOP=1 -tAqc \
    "SELECT COUNT(*)::text || ':' || md5(COALESCE(string_agg(note, chr(44) ORDER BY id), '')) FROM recovery_markers;")"
  stats="$(echo "$stats" | tr -d '[:space:]')"
  SOURCE_ROW_COUNT="${stats%%:*}"
  SOURCE_CHECKSUM="${stats#*:}"
  if ! [[ "$SOURCE_ROW_COUNT" =~ ^[0-9]+$ && -n "$SOURCE_CHECKSUM" && "$SOURCE_CHECKSUM" =~ ^[0-9a-f]{32}$ ]]; then
    echo "failed to collect source proof stats (raw=${stats})" >&2
    exit 1
  fi
  SOURCE_SCHEMA_HASH="$(kubectl -n "$DEMO_NS" exec "sts/${DEMO_STS}" -- \
    sh -c "pg_dump -U postgres -d app --schema-only 2>/dev/null | sha256sum | awk '{print \$1}'" | tr -d '[:space:]')"

  cat >"$MARKER_FILE" <<EOF
MARKER_UUID=${MARKER_UUID}
MARKER_NOTE=${MARKER_NOTE}
MARKER_TS=${MARKER_TS}
SOURCE_ROW_COUNT=${SOURCE_ROW_COUNT}
SOURCE_CHECKSUM=${SOURCE_CHECKSUM}
SOURCE_SCHEMA_HASH=${SOURCE_SCHEMA_HASH}
EOF
  echo "   marker rows=${SOURCE_ROW_COUNT} checksum=${SOURCE_CHECKSUM:0:12}…"
}

emit_evidence() {
  python3 - "$EVIDENCE_DIR" "$DRILL_ID" "$SCENARIO" "$BLOCKED_AT" \
    "$BACKUP_AS" "$RESTORE_AS" "$DRILL_NS" "$BACKUP_LOC" \
    "$checks_backup" "$checks_artifact" "$checks_restore" \
    "$checks_health" "$checks_data" "$checks_rto" "$checks_fresh" \
    "${RPO_SECONDS}" "${RTO_SECONDS}" \
    "$MARKER_UUID" "$MARKER_NOTE" "$MARKER_TS" \
    "$SOURCE_ROW_COUNT" "$SOURCE_CHECKSUM" "$SOURCE_SCHEMA_HASH" \
    "$BACKUP_SHA" "$BACKUP_TS" "$RTO_TARGET" <<'PY'
import json, sys, pathlib
from datetime import datetime, timezone

(
  out_dir, drill_id, scenario, blocked, backup_as, restore_as, drill_ns, backup_loc,
  c_backup, c_art, c_rest, c_health, c_data, c_rto, c_fresh, rpo, rto,
  marker_uuid, marker_note, marker_ts, row_count, checksum, schema_hash,
  backup_sha, backup_ts, rto_target,
) = sys.argv[1:]

def b(x):
  return str(x).lower() in ("true", "1", "yes")

def ni(x):
  return int(x) if x not in ("", "null", "None") else None

def ns(x):
  return x if x not in ("", "null", "None") else None

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
    "rto_target_seconds": ni(rto_target),
    "drill_id": int(drill_id),
  },
  "proof": {
    "marker_uuid": ns(marker_uuid),
    "marker_note": ns(marker_note),
    "marker_written_at": ns(marker_ts),
    "source_row_count": ni(row_count),
    "source_checksum": ns(checksum),
    "source_schema_hash": ns(schema_hash),
    "backup_sha256": ns(backup_sha),
    "backup_timestamp": ns(backup_ts),
  },
}
out = pathlib.Path(out_dir)
latest = out / "drill-latest.json"
latest.write_text(json.dumps(ev, indent=2) + "\n")
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
(out / f"drill-{stamp}.json").write_text(latest.read_text())
print(f"wrote {latest}")
PY

  set +e
  "$ROOT/scripts/evaluate-contract.sh" "$EVIDENCE_DIR/drill-latest.json"
  EVAL_RC=$?
  set -e

  if [[ "$SCENARIO" != "happy-path" ]]; then
    rm -f "$STATE_FILE"
    echo "-- failure scenario state cleared"
  fi
}

finish() {
  cleanup_old_drills || true
  "$ROOT/scripts/collect-evidence.sh" || true
  # Happy path must be PROVED (exit 0). Expected-failure scenarios must be
  # UNPROVED with the contracted reason (exit 0 from the drill wrapper).
  if [[ "$SCENARIO" == "happy-path" ]]; then
    if [[ "$EVAL_RC" -ne 0 ]]; then
      echo "happy-path expected PROVED but evaluator exited ${EVAL_RC}" >&2
      exit "$EVAL_RC"
    fi
    exit 0
  fi

  EXPECTED="$(python3 -c '
import json,sys
cfg=json.load(open(sys.argv[1]))
print(cfg.get("failure_scenarios",{}).get(sys.argv[2],{}).get("expected_reason",""))
' "$CONTRACT_JSON" "$SCENARIO")"
  ACTUAL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reason") or "")' "$EVIDENCE_DIR/recovery-verdict.json")"
  VERDICT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("verdict") or "")' "$EVIDENCE_DIR/recovery-verdict.json")"
  if [[ "$VERDICT" != "UNPROVED" ]]; then
    echo "scenario ${SCENARIO} expected UNPROVED, got ${VERDICT}" >&2
    exit 1
  fi
  if [[ -n "$EXPECTED" && "$ACTUAL" != "$EXPECTED" ]]; then
    echo "scenario ${SCENARIO} expected reason=${EXPECTED}, got ${ACTUAL}" >&2
    exit 1
  fi
  echo "-- scenario ${SCENARIO}: UNPROVED reason=${ACTUAL} (expected)"
  exit 0
}

# --- PROTECT ---
# Ensure demo app exists before inserting the proof marker.
kubectl apply -f "$ROOT/examples/postgres-statefulset.yaml" >/dev/null
kubectl -n "$DEMO_NS" rollout status "statefulset/${DEMO_STS}" --timeout=180s
if kubectl -n "$DEMO_NS" get job/postgres-seed >/dev/null 2>&1; then
  kubectl -n "$DEMO_NS" wait --for=condition=complete job/postgres-seed --timeout=180s || true
fi

insert_proof_marker

echo "-- protect: creating backup (unique object key)"
"$ROOT/scripts/backup-drill.sh"
BACKUP_AS="$(kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
BACKUP_STATE="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.state}' 2>/dev/null || true)"

if [[ "$BACKUP_STATE" == "complete" ]]; then
  checks_backup=true
else
  BLOCKED_AT="protect"
fi

BACKUP_LOC="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupLocation}' 2>/dev/null || true)"
BACKUP_SHA="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupSha256}' 2>/dev/null || true)"
BACKUP_TS="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupTimestamp}' 2>/dev/null || true)"
if [[ -z "$BACKUP_TS" ]]; then
  BACKUP_TS="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
fi

# RPO from actual backup timestamp vs marker write time (data age at backup).
if [[ -n "$BACKUP_TS" && -n "$MARKER_TS" ]]; then
  BACKUP_EPOCH="$(iso_to_epoch "$BACKUP_TS" || true)"
  MARKER_EPOCH="$(iso_to_epoch "$MARKER_TS" || true)"
  if [[ -n "${BACKUP_EPOCH:-}" && -n "${MARKER_EPOCH:-}" ]]; then
    RPO_SECONDS=$((BACKUP_EPOCH - MARKER_EPOCH))
    if [[ "$RPO_SECONDS" -lt 0 ]]; then
      RPO_SECONDS=0
    fi
  fi
fi
# Fallback: age of backup ActionSet creation.
if [[ -z "${RPO_SECONDS}" ]]; then
  BACKUP_CREATED="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
  if [[ -n "$BACKUP_CREATED" ]]; then
    BACKUP_EPOCH="$(iso_to_epoch "$BACKUP_CREATED" || true)"
    if [[ -n "${BACKUP_EPOCH:-}" ]]; then
      RPO_SECONDS=$(($(now_epoch) - BACKUP_EPOCH))
    fi
  fi
fi

echo "-- protect: backup=${BACKUP_AS} loc=${BACKUP_LOC} sha256=${BACKUP_SHA:0:12}… ($([[ $checks_backup == true ]] && echo PASS || echo FAIL))"

"$ROOT/scripts/prune-backups.sh" "$BACKUP_RETAIN_N" || true

if [[ "$checks_backup" != true ]]; then
  emit_evidence
  finish
fi

if [[ "$SCENARIO" == "corrupt-artifact" ]]; then
  echo "-- protect: corrupting artifact at drills/${BACKUP_LOC}"
  CORRUPT="$(mktemp)"
  printf 'NOT-A-GZIP-ARTIFACT' >"$CORRUPT"
  "$ROOT/scripts/s3-object.sh" put "drills/${BACKUP_LOC}" "$CORRUPT"
  rm -f "$CORRUPT"
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
  finish
fi

# --- RESTORE ---
DRILL_NS="restore-drill-$(date -u +%Y%m%d%H%M%S)"
RESTORE_AS="restore-postgres-$(date -u +%Y%m%d%H%M%S)"
RESTORE_BP="postgres-app-aware"
if [[ "$SCENARIO" == "noop-restore" ]]; then
  RESTORE_BP="postgres-noop-restore"
  echo "-- restore: noop-restore blueprint (skip data restore)"
fi
echo "-- restore into ${DRILL_NS} (unseeded)"

# Bring up empty Postgres first (env bring-up is NOT part of RTO).
sed -e "s/name: restore-target/name: ${DRILL_NS}/g" \
  -e "s/namespace: restore-target/namespace: ${DRILL_NS}/g" \
  "$ROOT/examples/postgres-restore-target.yaml" | kubectl apply -f -
kubectl -n "$DRILL_NS" rollout status statefulset/postgres --timeout=180s

# Negative proof: empty DB must not already contain the marker.
PRE_COUNT="$(kubectl -n "$DRILL_NS" exec sts/postgres -- \
  psql -U postgres -d app -tAc "SELECT COUNT(*) FROM recovery_markers WHERE note='${MARKER_NOTE}'" 2>/dev/null || echo 0)"
PRE_COUNT="$(echo "$PRE_COUNT" | tr -d '[:space:]')"
if [[ -n "$PRE_COUNT" && "$PRE_COUNT" != "0" && "$PRE_COUNT" != "" ]]; then
  echo "   ERROR: unseeded target already has marker (count=${PRE_COUNT})" >&2
  BLOCKED_AT="verify"
  emit_evidence
  finish
fi

if [[ "$SCENARIO" == "wrong-secret" ]]; then
  echo "   injecting wrong-secret"
  kubectl -n "$DRILL_NS" create secret generic postgres-credentials \
    --from-literal=POSTGRES_USER=postgres \
    --from-literal=POSTGRES_PASSWORD="${BREAK_BAD_PASSWORD:-wrong}" \
    --from-literal=POSTGRES_DB=app \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# RTO clock starts at ActionSet creation (restore work only; env bring-up excluded).
START=$(now_epoch)
if [[ "$SCENARIO" == "slow-restore" ]]; then
  echo "   injecting slow-restore sleep ${BREAK_RTO_SLEEP_SECONDS:-75}s (counts toward RTO)"
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
      blueprint: ${RESTORE_BP}
      artifacts:
        cloudObject:
          keyValue:
            backupLocation: "${BACKUP_LOC}"
            backupSha256: "${BACKUP_SHA}"
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
    complete)
      RESTORE_OK=true
      break
      ;;
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
  kubectl -n "$PROFILE_NS" describe "actionset/${RESTORE_AS}" >&2 || true
  kubectl get pods -A | grep -E 'kanister-job|NAME' >&2 || true
  for p in $(kubectl -n "$DRILL_NS" get pods -o name 2>/dev/null | grep kanister-job || true); do
    echo "=== logs ${DRILL_NS}/${p} ===" >&2
    kubectl -n "$DRILL_NS" logs "$p" --tail=80 >&2 || true
  done
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

  FOUND="$(kubectl -n "$DRILL_NS" exec sts/postgres -- \
    psql -U postgres -d app -tAc "SELECT COUNT(*) FROM recovery_markers WHERE note='${MARKER_NOTE}'" 2>/dev/null || echo 0)"
  FOUND="$(echo "$FOUND" | tr -d '[:space:]')"
  RESTORE_STATS="$(kubectl -n "$DRILL_NS" exec sts/postgres -- \
    psql -U postgres -d app -tAc \
    "SELECT COUNT(*)::text || ':' || md5(COALESCE(string_agg(note, chr(44) ORDER BY id), '')) FROM recovery_markers;" \
    2>/dev/null || echo "0:")"
  RESTORE_STATS="$(echo "$RESTORE_STATS" | tr -d '[:space:]')"
  RESTORE_ROWS="${RESTORE_STATS%%:*}"
  RESTORE_CHECKSUM="${RESTORE_STATS#*:}"

  if [[ "$FOUND" == "1" && "$RESTORE_ROWS" == "$SOURCE_ROW_COUNT" && "$RESTORE_CHECKSUM" == "$SOURCE_CHECKSUM" ]]; then
    checks_data=true
    echo "   data_verification PASS (marker=${MARKER_UUID} rows=${RESTORE_ROWS})"
  else
    BLOCKED_AT="${BLOCKED_AT:-verify}"
    echo "   data_verification FAIL (found=${FOUND} rows=${RESTORE_ROWS}/${SOURCE_ROW_COUNT} checksum_match=$([[ "$RESTORE_CHECKSUM" == "$SOURCE_CHECKSUM" ]] && echo yes || echo no))"
  fi
fi

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
finish
