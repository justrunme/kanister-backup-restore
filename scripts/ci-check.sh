#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

echo "== required files =="
for f in \
  README.md LICENSE Makefile \
  config/recovery-slo.yaml config/recovery-slo.json \
  blueprints/postgres/blueprint.yaml \
  scripts/recovery-drill.sh scripts/break.sh scripts/compute-confidence.sh \
  deploy/minio-profile.yaml examples/postgres-statefulset.yaml
do
  [[ -f "$f" ]] || { echo "missing $f" >&2; fail=1; }
done

echo "== concept markers =="
grep -q 'Continuous Recovery Confidence' README.md || fail=1
grep -q 'Protect → Break → Restore → Prove' README.md || fail=1
grep -q 'Restore should be proved, not assumed' README.md || fail=1

echo "== scoring weights sum 100 =="
python3 - <<'PY' || fail=1
import json
from pathlib import Path
w=json.loads(Path("config/recovery-slo.json").read_text())["weights"]
assert sum(w.values())==100, w
assert set(w)=={"artifact_integrity","restore_completed","application_health","data_verification","rto_within_target","evidence_fresh"}
print("weights ok", w)
PY

echo "== break scenarios documented =="
for s in corrupt-artifact wrong-secret schema-drift slow-restore; do
  grep -q "$s" scripts/break.sh || { echo "missing scenario $s" >&2; fail=1; }
done

echo "== kando still present =="
grep -q 'kando location push' blueprints/postgres/blueprint.yaml || fail=1

if [[ "$fail" -ne 0 ]]; then
  echo "ci failed" >&2
  exit 1
fi
echo "ci checks passed"
