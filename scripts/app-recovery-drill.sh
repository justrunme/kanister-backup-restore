#!/usr/bin/env bash
# Application Recovery Contract: Postgres + S3 with cross-component consistency.
# Lifecycle: PROTECT → VALIDATE → RESTORE → PROVE (incl. consistency).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_NS="${PROFILE_NS:-kanister}"
PROFILE_NAME="${PROFILE_NAME:-s3-profile}"
DEMO_NS="${DEMO_NAMESPACE:-demo-postgres}"
DEMO_STS="${DEMO_STATEFULSET:-postgres}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/.evidence}"
STATE_FILE="$EVIDENCE_DIR/active-break.env"
SEQ_FILE="$EVIDENCE_DIR/drill-seq"
CONTRACT_JSON="$ROOT/config/recovery-contract.json"
mkdir -p "$EVIDENCE_DIR"

SCENARIO="happy-path"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  SCENARIO="${BREAK_SCENARIO:-happy-path}"
fi

RTO_TARGET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["contract"]["rto_seconds_max"])' "$CONTRACT_JSON")"
SKEW_MAX="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["contract"]; print(c.get("recovery_point_skew_seconds_max", 60))' "$CONTRACT_JSON")"

checks_backup=false
checks_artifact=false
checks_restore=false
checks_health=false
checks_data=false
checks_consistency=false
checks_rto=false
checks_fresh=true
RTO_SECONDS=""
RPO_SECONDS=""
DRILL_NS=""
BACKUP_AS=""
RESTORE_AS=""
BACKUP_LOC=""
BACKUP_SHA=""
BLOCKED_AT=""
RP_ID=""
EVAL_RC=0
CONSISTENCY_ERRORS=""

now_epoch() { date -u +%s; }

DRILL_ID=1
if [[ -f "$SEQ_FILE" ]]; then
  DRILL_ID=$(($(cat "$SEQ_FILE") + 1))
fi
echo "$DRILL_ID" >"$SEQ_FILE"

echo "== Application Recovery Contract drill #${DRILL_ID} · scenario=${SCENARIO} =="
echo "== PROTECT → VALIDATE → RESTORE → PROVE (consistency) =="

emit_evidence() {
  python3 - "$EVIDENCE_DIR" "$DRILL_ID" "$SCENARIO" "$BLOCKED_AT" \
    "$BACKUP_AS" "$RESTORE_AS" "$DRILL_NS" "$BACKUP_LOC" \
    "$checks_backup" "$checks_artifact" "$checks_restore" \
    "$checks_health" "$checks_data" "$checks_consistency" "$checks_rto" "$checks_fresh" \
    "${RPO_SECONDS}" "${RTO_SECONDS}" "$RTO_TARGET" "$RP_ID" "$BACKUP_SHA" \
    "$CONSISTENCY_ERRORS" <<'PY'
import json, sys, pathlib
from datetime import datetime, timezone

(
  out_dir, drill_id, scenario, blocked, backup_as, restore_as, drill_ns, backup_loc,
  c_backup, c_art, c_rest, c_health, c_data, c_cons, c_rto, c_fresh, rpo, rto, rto_target,
  rp_id, backup_sha, cons_errors,
) = sys.argv[1:]

def b(x):
  return str(x).lower() in ("true", "1", "yes")

def ni(x):
  return int(x) if x not in ("", "null", "None") else None

def ns(x):
  return x if x not in ("", "null", "None") else None

rp = None
rp_path = pathlib.Path(out_dir) / "recovery-point.json"
if rp_path.is_file():
  rp = json.loads(rp_path.read_text())

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
    "cross_component_consistency": b(c_cons),
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
    "rp_id": ns(rp_id),
    "backup_sha256": ns(backup_sha),
    "consistency_errors": [e for e in (cons_errors or "").split("||") if e],
    "recovery_point": rp,
  },
  "components": {"postgres": True, "s3": True},
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
  kubectl delete ns -l justrunme.com/role=restore-drill --wait=false --ignore-not-found >/dev/null 2>&1 || true
  "$ROOT/scripts/collect-evidence.sh" || true
  if [[ "$SCENARIO" == "happy-path" ]]; then
    [[ "$EVAL_RC" -eq 0 ]] || exit "$EVAL_RC"
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
kubectl apply -f "$ROOT/examples/postgres-statefulset.yaml" >/dev/null
kubectl -n "$DEMO_NS" rollout status "statefulset/${DEMO_STS}" --timeout=180s
kubectl -n "$DEMO_NS" wait --for=condition=complete job/postgres-seed --timeout=180s || true
"$ROOT/scripts/seed-linked-app.sh"

"$ROOT/scripts/backup-recovery-point.sh"
RP_ID="$(cat "$EVIDENCE_DIR/active-rp-id")"
BACKUP_AS="$(python3 -c 'import json; print(json.load(open("'"$EVIDENCE_DIR"'/recovery-point.json"))["postgres"]["actionset"])')"
BACKUP_LOC="$(python3 -c 'import json; print(json.load(open("'"$EVIDENCE_DIR"'/recovery-point.json"))["postgres"]["backup_location"])')"
BACKUP_SHA="$(python3 -c 'import json; print(json.load(open("'"$EVIDENCE_DIR"'/recovery-point.json"))["postgres"]["backup_sha256"])')"
PG_TS="$(python3 -c 'import json; print(json.load(open("'"$EVIDENCE_DIR"'/recovery-point.json"))["pg_backup_timestamp"])')"
S3_TS="$(python3 -c 'import json; print(json.load(open("'"$EVIDENCE_DIR"'/recovery-point.json"))["s3_backup_timestamp"])')"

checks_backup=true
# RPO from RP timestamps (max age of components relative to each other already in skew;
# RPO reported as age from earliest component timestamp to now for display, or pg-s3 delta)
python3 - "$PG_TS" "$S3_TS" <<'PY' >"$EVIDENCE_DIR/rpo.env"
import sys
from datetime import datetime, timezone
def p(v):
  raw=v.strip()
  if raw.endswith("Z"): raw=raw[:-1]+"+00:00"
  return datetime.fromisoformat(raw).astimezone(timezone.utc)
a,b=p(sys.argv[1]),p(sys.argv[2])
print(f"RPO_SECONDS={abs(int((a-b).total_seconds()))}")
PY
# shellcheck disable=SC1090
source "$EVIDENCE_DIR/rpo.env"
echo "-- protect: rp=${RP_ID} backup=${BACKUP_AS} (PASS) rpo=${RPO_SECONDS}s"

# Failure injections against the recovery point object store
if [[ "$SCENARIO" == "delete-s3-object" ]]; then
  VICTIM="$(python3 -c 'import json; print(json.load(open("'"$EVIDENCE_DIR"'/recovery-point.json"))["objects"][0]["backup_key"])')"
  echo "-- inject delete-s3-object: ${VICTIM}"
  "$ROOT/scripts/s3-object.sh" delete "$VICTIM"
fi
if [[ "$SCENARIO" == "corrupt-s3-object" ]]; then
  VICTIM="$(python3 -c 'import json; print(json.load(open("'"$EVIDENCE_DIR"'/recovery-point.json"))["objects"][0]["backup_key"])')"
  echo "-- inject corrupt-s3-object: ${VICTIM}"
  BAD="$(mktemp)"
  printf 'CORRUPTED-OBJECT-BYTES' >"$BAD"
  "$ROOT/scripts/s3-object.sh" put "$VICTIM" "$BAD"
  rm -f "$BAD"
fi
if [[ "$SCENARIO" == "mismatched-recovery-points" ]]; then
  echo "-- inject mismatched-recovery-points: create second RP and mix components"
  "$ROOT/scripts/seed-linked-app.sh"
  "$ROOT/scripts/backup-recovery-point.sh"
  # Keep S3 objects from the NEW rp, but force postgres backup location from the OLD rp
  OLD_PG_LOC="$BACKUP_LOC"
  OLD_PG_SHA="$BACKUP_SHA"
  OLD_PG_AS="$BACKUP_AS"
  python3 - "$EVIDENCE_DIR/recovery-point.json" "$OLD_PG_LOC" "$OLD_PG_SHA" "$OLD_PG_AS" "$PG_TS" <<'PY'
import json, sys, pathlib
path, loc, sha, actionset, pg_ts = sys.argv[1:6]
rp = json.loads(pathlib.Path(path).read_text())
rp["postgres"] = {"actionset": actionset, "backup_location": loc, "backup_sha256": sha}
# Force large skew / mismatched generations: keep new S3 generation but old pg pointer
rp["pg_backup_timestamp"] = pg_ts
rp["mismatch_injected"] = True
pathlib.Path(path).write_text(json.dumps(rp, indent=2) + "\n")
print("mixed RP postgres<-old s3<-new")
PY
  RP_ID="$(cat "$EVIDENCE_DIR/active-rp-id")"
  BACKUP_LOC="$OLD_PG_LOC"
  BACKUP_SHA="$OLD_PG_SHA"
  BACKUP_AS="$OLD_PG_AS"
fi

# --- VALIDATE ---
echo "-- validate postgres artifact + RP manifest"
set +e
FROM_ACTIONSET="$BACKUP_AS" ACTION=validate "$ROOT/scripts/run-action.sh"
VAL_RC=$?
set -e
MANIFEST_OK=false
if "$ROOT/scripts/s3-object.sh" head "recovery-points/${RP_ID}/manifest.json"; then
  MANIFEST_OK=true
fi
if [[ $VAL_RC -eq 0 && "$MANIFEST_OK" == true ]]; then
  checks_artifact=true
  echo "   artifact_integrity PASS"
else
  BLOCKED_AT="validate"
  echo "   artifact_integrity FAIL"
  RTO_SECONDS=0
  emit_evidence
  finish
fi

# --- RESTORE ---
DRILL_NS="restore-drill-$(date -u +%Y%m%d%H%M%S)"
RESTORE_AS="restore-postgres-$(date -u +%Y%m%d%H%M%S)"
echo "-- restore into ${DRILL_NS} (unseeded) + S3 objects from RP"

sed -e "s/name: restore-target/name: ${DRILL_NS}/g" \
  -e "s/namespace: restore-target/namespace: ${DRILL_NS}/g" \
  "$ROOT/examples/postgres-restore-target.yaml" | kubectl apply -f -
kubectl label ns "$DRILL_NS" justrunme.com/role=restore-drill --overwrite >/dev/null
kubectl -n "$DRILL_NS" apply -f "$ROOT/deploy/drill-quota.yaml" >/dev/null
kubectl -n "$DRILL_NS" rollout status statefulset/postgres --timeout=180s

START=$(now_epoch)
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

# Restore S3 objects from RP into a local staging dir (and optionally re-upload under drill prefix)
OBJ_DIR="$EVIDENCE_DIR/restored-objects-${RP_ID}"
mkdir -p "$OBJ_DIR"
S3_RESTORE_OK=true
while IFS= read -r line; do
  bkey="$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["backup_key"])')"
  bname="$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["backup_name"])')"
  if ! "$ROOT/scripts/s3-object.sh" get "$bkey" "$OBJ_DIR/$bname"; then
    S3_RESTORE_OK=false
    echo "   failed to pull ${bkey}" >&2
  fi
done < <(python3 -c 'import json,sys; [print(json.dumps(o)) for o in json.load(open(sys.argv[1]))["objects"]]' "$EVIDENCE_DIR/recovery-point.json")

END=$(now_epoch)
RTO_SECONDS=$((END - START))

if [[ "$RESTORE_OK" == true && "$S3_RESTORE_OK" == true ]]; then
  checks_restore=true
  echo "   isolated_restore PASS (rto=${RTO_SECONDS}s)"
elif [[ "$RESTORE_OK" == true && "$S3_RESTORE_OK" != true ]]; then
  # PG restored but S3 incomplete — still mark restore_completed for PG path,
  # consistency will fail (required for delete/corrupt scenarios).
  checks_restore=true
  echo "   isolated_restore PASS (postgres) / S3 incomplete (consistency will fail)"
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

  # Data verification: linked tables present with rows
  ROW_COUNT="$(kubectl -n "$DRILL_NS" exec sts/postgres -- \
    psql -U postgres -d app -tAc 'SELECT COUNT(*) FROM app_objects;' 2>/dev/null || echo 0)"
  ROW_COUNT="$(echo "$ROW_COUNT" | tr -d '[:space:]')"
  if [[ "$ROW_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    checks_data=true
    echo "   data_verification PASS (app_objects=${ROW_COUNT})"
  else
    BLOCKED_AT="${BLOCKED_AT:-verify}"
    echo "   data_verification FAIL (app_objects=${ROW_COUNT})"
  fi

  # Export PG rows + generation for consistency proof
  PG_ROWS="$EVIDENCE_DIR/prove-rows.json"
  kubectl -n "$DRILL_NS" exec sts/postgres -- \
    psql -U postgres -d app -tAc \
    "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
       SELECT object_key, sha256, generation FROM app_objects ORDER BY id
     ) t;" >"$PG_ROWS" || echo '[]' >"$PG_ROWS"
  PG_GEN="$(kubectl -n "$DRILL_NS" exec sts/postgres -- \
    psql -U postgres -d app -tAc 'SELECT COALESCE(MAX(generation),0) FROM app_manifest;' 2>/dev/null || echo 0)"
  PG_GEN="$(echo "$PG_GEN" | tr -d '[:space:]')"

  set +e
  PROVE_OUT="$(python3 "$ROOT/scripts/prove_consistency.py" \
    "$PG_ROWS" "$PG_GEN" "$OBJ_DIR" "$EVIDENCE_DIR/recovery-point.json" "$SKEW_MAX")"
  PROVE_RC=$?
  set -e
  echo "$PROVE_OUT"
  if [[ $PROVE_RC -eq 0 ]]; then
    checks_consistency=true
    echo "   cross_component_consistency PASS"
  else
    BLOCKED_AT="${BLOCKED_AT:-consistency}"
    CONSISTENCY_ERRORS="$(echo "$PROVE_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("||".join(d.get("errors") or []))' 2>/dev/null || true)"
    echo "   cross_component_consistency FAIL"
  fi
fi

if [[ -n "$RTO_SECONDS" && "$RTO_SECONDS" -le "$RTO_TARGET" && "$checks_restore" == true ]]; then
  checks_rto=true
else
  checks_rto=false
fi
echo "   rto $([[ $checks_rto == true ]] && echo PASS || echo FAIL) (${RTO_SECONDS}s / ${RTO_TARGET}s)"

emit_evidence
finish
