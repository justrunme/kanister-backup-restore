#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

echo "== required files =="
for f in \
  README.md LICENSE Makefile \
  config/recovery-contract.yaml config/recovery-contract.json \
  docs/assets/recovery-lifecycle.svg \
  blueprints/postgres/blueprint.yaml \
  scripts/recovery-drill.sh scripts/break.sh scripts/evaluate-contract.sh scripts/failure-drill.sh \
  deploy/minio-profile.yaml examples/postgres-statefulset.yaml
do
  [[ -f "$f" ]] || { echo "missing $f" >&2; fail=1; }
done

echo "== concept markers =="
grep -q 'Recovery Contract' README.md || fail=1
grep -q 'PROTECT → VALIDATE → RESTORE → PROVE' README.md || fail=1
grep -q 'Restore should be proved, not assumed' README.md || fail=1
grep -q 'PROVED' README.md || fail=1
grep -q 'UNPROVED' README.md || fail=1
! grep -q 'Confidence.*100' README.md || { echo "percentage score still in README" >&2; fail=1; }

echo "== contract schema =="
python3 - <<'PY' || fail=1
import json
from pathlib import Path
c=json.loads(Path("config/recovery-contract.json").read_text())["contract"]
for k in ("artifact_integrity","isolated_restore","application_ready","data_verification","rto_seconds_max","evidence_freshness_hours_max"):
    assert k in c, k
assert c["rto_seconds_max"] == 60
assert "weights" not in json.loads(Path("config/recovery-contract.json").read_text())
print("contract ok", c)
PY

echo "== evaluate-contract offline =="
mkdir -p .evidence-ci
python3 - <<'PY'
import json, pathlib
p = pathlib.Path(".evidence-ci/drill-latest.json")
p.write_text(json.dumps({
  "drill_id": 42,
  "scenario": "happy-path",
  "blocked_at": None,
  "backup_actionset": "backup-x",
  "restore_actionset": "restore-x",
  "drill_namespace": "restore-drill-x",
  "backup_location": "obj.sql.gz",
  "collected_at": "2026-09-06T12:00:00Z",
  "checks": {
    "backup": True,
    "artifact_integrity": True,
    "restore_completed": True,
    "application_health": True,
    "data_verification": True,
    "rto_within_target": True,
    "evidence_fresh": True
  },
  "metrics": {"rpo_seconds": 221, "rto_seconds": 38, "evidence_age_hours": 0, "drill_id": 42}
}) + "\n")
fail = pathlib.Path(".evidence-ci/drill-fail.json")
fail.write_text(json.dumps({
  "drill_id": 43,
  "scenario": "corrupt-artifact",
  "blocked_at": "validate",
  "backup_actionset": "backup-x",
  "restore_actionset": None,
  "drill_namespace": None,
  "backup_location": "obj.sql.gz",
  "collected_at": "2026-09-06T12:00:00Z",
  "checks": {
    "backup": True,
    "artifact_integrity": False,
    "restore_completed": False,
    "application_health": False,
    "data_verification": False,
    "rto_within_target": False,
    "evidence_fresh": True
  },
  "metrics": {"rpo_seconds": 10, "rto_seconds": 0, "evidence_age_hours": 0, "drill_id": 43}
}) + "\n")
PY
EVIDENCE_DIR=.evidence-ci ./scripts/evaluate-contract.sh .evidence-ci/drill-latest.json | tee /tmp/rc-prove.out
grep -q 'PROVED' /tmp/rc-prove.out || fail=1
grep -q 'RECOVERY DRILL #0042' /tmp/rc-prove.out || fail=1
EVIDENCE_DIR=.evidence-ci ./scripts/evaluate-contract.sh .evidence-ci/drill-fail.json | tee /tmp/rc-fail.out
grep -q 'UNPROVED' /tmp/rc-fail.out || fail=1
grep -q 'artifact_integrity' /tmp/rc-fail.out || fail=1
rm -rf .evidence-ci

echo "== failure scenarios =="
for s in corrupt-artifact wrong-secret schema-drift slow-restore; do
  grep -q "$s" scripts/break.sh || { echo "missing scenario $s" >&2; fail=1; }
done
grep -q 'failure-drill' Makefile || fail=1

echo "== kando still present =="
grep -q 'kando location push' blueprints/postgres/blueprint.yaml || fail=1

# stale score files must be gone
[[ ! -f config/recovery-slo.json ]] || { echo "stale recovery-slo.json" >&2; fail=1; }
[[ ! -f scripts/compute-confidence.sh ]] || { echo "stale compute-confidence.sh" >&2; fail=1; }

if [[ "$fail" -ne 0 ]]; then
  echo "ci failed" >&2
  exit 1
fi
echo "ci checks passed"
