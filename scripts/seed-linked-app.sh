#!/usr/bin/env bash
# Seed linked Postgres + S3 application state (object key, sha256, generation).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO_NS="${DEMO_NAMESPACE:-demo-postgres}"
DEMO_STS="${DEMO_STATEFULSET:-postgres}"
OBJECT_COUNT="${LINKED_OBJECT_COUNT:-3}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/.evidence}"
mkdir -p "$EVIDENCE_DIR"

echo "== seed linked app state in ${DEMO_NS} =="

kubectl -n "$DEMO_NS" exec -i "sts/${DEMO_STS}" -- \
  psql -U postgres -d app -v ON_ERROR_STOP=1 -q <"$ROOT/examples/linked-app/schema.sql"

GENERATION="$(date -u +%s)"
OBJECTS_JSON="$EVIDENCE_DIR/linked-objects.json"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

python3 - "$OBJECT_COUNT" "$GENERATION" "$TMPDIR" "$OBJECTS_JSON" <<'PY'
import hashlib, json, pathlib, sys, uuid
count, generation, tmp, out = int(sys.argv[1]), int(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4])
objs = []
for i in range(count):
    key = f"app-data/gen-{generation}/obj-{i}-{uuid.uuid4().hex[:8]}.bin"
    payload = f"linked-payload-{generation}-{i}-{uuid.uuid4()}\n".encode()
    path = tmp / f"obj-{i}.bin"
    path.write_bytes(payload)
    sha = hashlib.sha256(payload).hexdigest()
    objs.append({"object_key": key, "sha256": sha, "generation": generation, "local_path": str(path)})
out.write_text(json.dumps({"generation": generation, "objects": objs}, indent=2) + "\n")
print(f"prepared {len(objs)} objects generation={generation}")
PY

# Upload objects to S3
while IFS= read -r line; do
  key="$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["object_key"])')"
  path="$(echo "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["local_path"])')"
  "$ROOT/scripts/s3-object.sh" put "$key" "$path"
done < <(python3 -c 'import json,sys; [print(json.dumps(o)) for o in json.load(open(sys.argv[1]))["objects"]]' "$OBJECTS_JSON")

# Insert DB rows + bump manifest generation
python3 - "$OBJECTS_JSON" <<'PY' | kubectl -n "$DEMO_NS" exec -i "sts/${DEMO_STS}" -- \
  psql -U postgres -d app -v ON_ERROR_STOP=1 -q
import json, sys
data = json.load(open(sys.argv[1]))
gen = data["generation"]
print("BEGIN;")
print(f"INSERT INTO app_manifest (id, generation, updated_at) VALUES (1, {gen}, now())")
print(f"  ON CONFLICT (id) DO UPDATE SET generation = EXCLUDED.generation, updated_at = now();")
# Replace prior generations so app_objects is a single logical version.
print("DELETE FROM app_objects;")
for o in data["objects"]:
    key = o["object_key"].replace("'", "''")
    sha = o["sha256"].replace("'", "''")
    print(
        "INSERT INTO app_objects (object_key, sha256, generation) VALUES "
        f"('{key}', '{sha}', {gen});"
    )
print("COMMIT;")
print(f"SELECT generation FROM app_manifest WHERE id = 1;")
print(f"SELECT COUNT(*) FROM app_objects;")
print(f"SELECT COUNT(DISTINCT generation) FROM app_objects;")
PY

echo "$GENERATION" >"$EVIDENCE_DIR/linked-generation"
echo "linked app seeded generation=${GENERATION} objects=${OBJECT_COUNT}"
