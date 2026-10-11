#!/usr/bin/env bash
# Create a multi-service logical recovery point: Postgres dump + S3 object copies + manifest.
# Writes RP metadata to $EVIDENCE_DIR/recovery-point.json
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_NS="${PROFILE_NS:-kanister}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/.evidence}"
DEMO_NS="${DEMO_NAMESPACE:-demo-postgres}"
DEMO_STS="${DEMO_STATEFULSET:-postgres}"
mkdir -p "$EVIDENCE_DIR"

RP_ID="rp-$(date -u +%Y%m%dT%H%M%SZ)-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:10])')"
RP_PREFIX="recovery-points/${RP_ID}"
echo "== create recovery point ${RP_ID} =="

# Ensure linked state exists
if ! kubectl -n "$DEMO_NS" exec "sts/${DEMO_STS}" -- \
  psql -U postgres -d app -tAc "SELECT COUNT(*) FROM app_objects" 2>/dev/null | grep -Eq '^[1-9]'; then
  "$ROOT/scripts/seed-linked-app.sh"
fi

GENERATION="$(kubectl -n "$DEMO_NS" exec "sts/${DEMO_STS}" -- \
  psql -U postgres -d app -tAc 'SELECT generation FROM app_manifest WHERE id = 1;' | tr -d '[:space:]')"
ROWS_JSON="$EVIDENCE_DIR/rp-pg-rows.json"
kubectl -n "$DEMO_NS" exec "sts/${DEMO_STS}" -- \
  psql -U postgres -d app -tAqc \
  "SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json) FROM (
     SELECT object_key, sha256, generation FROM app_objects ORDER BY id
   ) t;" | tr -d '[:space:]' >"$ROWS_JSON"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d,list) and d; print(f"rows ok count={len(d)}")' "$ROWS_JSON"

PG_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "-- backup postgres via Kanister"
"$ROOT/scripts/backup-drill.sh"
BACKUP_AS="$(kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
BACKUP_LOC="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupLocation}')"
BACKUP_SHA="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupSha256}')"
BACKUP_TS="$(kubectl -n "$PROFILE_NS" get "actionset/${BACKUP_AS}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupTimestamp}')"
[[ -n "$BACKUP_TS" ]] || BACKUP_TS="$PG_TS"

S3_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "-- copy referenced S3 objects under ${RP_PREFIX}/objects/"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

python3 - "$ROWS_JSON" "$RP_ID" "$GENERATION" "$BACKUP_AS" "$BACKUP_LOC" "$BACKUP_SHA" \
  "$BACKUP_TS" "$S3_TS" "$RP_PREFIX" "$EVIDENCE_DIR/recovery-point.json" "$TMPDIR" <<'PY'
import json, pathlib, sys, hashlib
rows_path, rp_id, generation, backup_as, backup_loc, backup_sha, pg_ts, s3_ts, prefix, out, tmp = sys.argv[1:]
rows = json.loads(pathlib.Path(rows_path).read_text())
objects = []
for i, row in enumerate(rows):
    backup_name = f"obj-{i:03d}-{hashlib.sha256(row['object_key'].encode()).hexdigest()[:12]}.bin"
    objects.append({
        "object_key": row["object_key"],
        "sha256": row["sha256"],
        "generation": int(row["generation"]),
        "backup_key": f"{prefix}/objects/{backup_name}",
        "backup_name": backup_name,
    })
manifest = {
    "rp_id": rp_id,
    "generation": int(generation),
    "created_at": s3_ts,
    "pg_backup_timestamp": pg_ts,
    "s3_backup_timestamp": s3_ts,
    "postgres": {
        "actionset": backup_as,
        "backup_location": backup_loc,
        "backup_sha256": backup_sha,
    },
    "objects": objects,
}
pathlib.Path(out).write_text(json.dumps(manifest, indent=2) + "\n")
# write copy plan for shell
plan = pathlib.Path(tmp) / "copy-plan.json"
plan.write_text(json.dumps(objects, indent=2) + "\n")
print(f"manifest objects={len(objects)} generation={generation}")
PY

MANIFEST_LOCAL="$TMPDIR/manifest.json"
cp "$EVIDENCE_DIR/recovery-point.json" "$MANIFEST_LOCAL"
"$ROOT/scripts/s3-object.sh" put "${RP_PREFIX}/manifest.json" "$MANIFEST_LOCAL"

while IFS= read -r line; do
  src="$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["object_key"])')"
  dst="$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["backup_key"])')"
  "$ROOT/scripts/s3-object.sh" copy "$src" "$dst"
done < <(python3 -c 'import json,sys; [print(json.dumps(o)) for o in json.load(open(sys.argv[1]))["objects"]]' "$EVIDENCE_DIR/recovery-point.json")

echo "$RP_ID" >"$EVIDENCE_DIR/active-rp-id"
echo "recovery point ready: ${RP_ID}"
cat "$EVIDENCE_DIR/recovery-point.json"
