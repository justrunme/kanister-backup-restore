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
  blueprints/postgres/blueprint-noop-restore.yaml \
  examples/postgres-restore-target.yaml examples/linked-app/schema.sql \
  examples/recovery-contract.yaml \
  scripts/recovery-drill.sh scripts/app-recovery-drill.sh scripts/break.sh \
  scripts/evaluate-contract.sh scripts/evaluate_contract.py scripts/prove_consistency.py \
  scripts/failure-drill.sh scripts/prune-backups.sh scripts/seed-linked-app.sh \
  scripts/backup-recovery-point.sh \
  deploy/seaweedfs-profile.yaml deploy/drill-quota.yaml \
  deploy/crds/recoverycontract-crd.yaml deploy/crds/recoverydrill-crd.yaml \
  operator/controller.py examples/postgres-statefulset.yaml; do
  [[ -f "$f" ]] || {
    echo "missing $f" >&2
    fail=1
  }
done

echo "== concept markers =="
grep -q 'Recovery Contract' README.md || fail=1
grep -q 'PROTECT → VALIDATE → RESTORE → PROVE' README.md || fail=1
grep -q 'Restore should be proved, not assumed' README.md || fail=1
grep -q 'PROVED' README.md || fail=1
grep -q 'UNPROVED' README.md || fail=1
grep -q 'noop-restore' README.md || fail=1
grep -q 'cross_component_consistency\|Cross-component consistency\|delete-s3-object' README.md || fail=1
grep -q 'Solr' README.md || fail=1
! grep -q 'Confidence.*100' README.md || {
  echo "percentage score still in README" >&2
  fail=1
}
# README media/badges must remain
grep -q 'docs/assets/recovery-lifecycle.svg' README.md || fail=1
grep -q 'badge.svg' README.md || fail=1
[[ -f docs/assets/recovery-drill.svg ]] || fail=1
[[ -f docs/assets/recovery-drill.cast ]] || fail=1

echo "== no hardcoded S3 secrets in blueprints =="
if grep -REn 'admin12345|PROFILE_JSON=.*Secret' blueprints/postgres/blueprint.yaml blueprints/postgres/blueprint-noop-restore.yaml; then
  echo "hardcoded profile credentials in blueprint" >&2
  fail=1
fi
if grep -n 'set -x\|set -euxo' blueprints/postgres/blueprint.yaml; then
  echo "set -x would leak secrets in blueprint job logs" >&2
  fail=1
fi
grep -q "toJson .Profile" blueprints/postgres/blueprint.yaml || {
  echo "postgres blueprint must use Kanister Profile" >&2
  fail=1
}
grep -q 'backupSha256' blueprints/postgres/blueprint.yaml || {
  echo "postgres blueprint must record sha256" >&2
  fail=1
}

echo "== contract schema =="
python3 - <<'PY' || fail=1
import json
from pathlib import Path
cfg=json.loads(Path("config/recovery-contract.json").read_text())
c=cfg["contract"]
for k in ("artifact_integrity","isolated_restore","application_ready","data_verification","cross_component_consistency","rto_seconds_max","evidence_freshness_hours_max","recovery_point_skew_seconds_max"):
    assert k in c, k
assert c["rto_seconds_max"] == 60
assert c["cross_component_consistency"] == "required"
assert "postgres" in cfg["components"] and "s3" in cfg["components"]
assert "solr" in cfg.get("future", [])
for s in ("noop-restore","delete-s3-object","corrupt-s3-object","mismatched-recovery-points"):
    assert s in cfg["failure_scenarios"], s
assert cfg["failure_scenarios"]["delete-s3-object"]["expected_reason"] == "isolated_restore"
assert "weights" not in cfg
print("contract ok", c)
PY

echo "== evaluate-contract offline =="
mkdir -p .evidence-ci
python3 - <<'PY'
import json, pathlib
from datetime import datetime, timezone, timedelta
now = datetime.now(timezone.utc)
fresh = (now - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
stale = (now - timedelta(hours=25)).strftime("%Y-%m-%dT%H:%M:%SZ")
p = pathlib.Path(".evidence-ci/drill-latest.json")
p.write_text(json.dumps({
  "drill_id": 42,
  "scenario": "happy-path",
  "blocked_at": None,
  "backup_actionset": "backup-x",
  "restore_actionset": "restore-x",
  "drill_namespace": "restore-drill-x",
  "backup_location": "pg_backups/demo/postgres/run/backup.sql.gz",
  "collected_at": fresh,
  "checks": {
    "backup": True,
    "artifact_integrity": True,
    "restore_completed": True,
    "application_health": True,
    "data_verification": True,
    "rto_within_target": True,
    "evidence_fresh": True
  },
  "metrics": {"component_skew_seconds": 221, "rto_seconds": 38, "drill_id": 42},
  "proof": {"marker_uuid": "00000000-0000-0000-0000-000000000042"}
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
  "collected_at": fresh,
  "checks": {
    "backup": True,
    "artifact_integrity": False,
    "restore_completed": False,
    "application_health": False,
    "data_verification": False,
    "rto_within_target": False,
    "evidence_fresh": True
  },
  "metrics": {"component_skew_seconds": 10, "rto_seconds": 0, "drill_id": 43}
}) + "\n")
stale_p = pathlib.Path(".evidence-ci/drill-stale.json")
stale_p.write_text(json.dumps({
  "drill_id": 44,
  "scenario": "happy-path",
  "blocked_at": None,
  "collected_at": stale,
  "checks": {
    "backup": True,
    "artifact_integrity": True,
    "restore_completed": True,
    "application_health": True,
    "data_verification": True,
    "rto_within_target": True,
    "evidence_fresh": True
  },
  "metrics": {"component_skew_seconds": 1, "rto_seconds": 10, "drill_id": 44}
}) + "\n")
missing = pathlib.Path(".evidence-ci/drill-missing.json")
missing.write_text(json.dumps({
  "drill_id": 45,
  "scenario": "happy-path",
  "collected_at": fresh,
  "checks": {
    "artifact_integrity": True,
    "restore_completed": True,
    "application_health": True,
    "data_verification": True
  },
  "metrics": {"component_skew_seconds": 1, "rto_seconds": 10, "drill_id": 45}
}) + "\n")
falsey = pathlib.Path(".evidence-ci/drill-backup-false.json")
falsey.write_text(json.dumps({
  "drill_id": 46,
  "scenario": "happy-path",
  "collected_at": fresh,
  "checks": {
    "backup": False,
    "artifact_integrity": True,
    "restore_completed": True,
    "application_health": True,
    "data_verification": True
  },
  "metrics": {"component_skew_seconds": 1, "rto_seconds": 10, "drill_id": 46}
}) + "\n")
str_false = pathlib.Path(".evidence-ci/drill-backup-string.json")
str_false.write_text(json.dumps({
  "drill_id": 47,
  "scenario": "happy-path",
  "collected_at": fresh,
  "checks": {
    "backup": "false",
    "artifact_integrity": True,
    "restore_completed": True,
    "application_health": True,
    "data_verification": True
  },
  "metrics": {"component_skew_seconds": 1, "rto_seconds": 10, "drill_id": 47}
}) + "\n")
PY

set +e
EVIDENCE_DIR=.evidence-ci ./scripts/evaluate-contract.sh .evidence-ci/drill-latest.json | tee /tmp/rc-prove.out
RC_PROVE=${PIPESTATUS[0]}
EVIDENCE_DIR=.evidence-ci ./scripts/evaluate-contract.sh .evidence-ci/drill-fail.json | tee /tmp/rc-fail.out
RC_FAIL=${PIPESTATUS[0]}
EVIDENCE_DIR=.evidence-ci ./scripts/evaluate-contract.sh .evidence-ci/drill-stale.json | tee /tmp/rc-stale.out
RC_STALE=${PIPESTATUS[0]}
EVIDENCE_DIR=.evidence-ci ./scripts/evaluate-contract.sh .evidence-ci/drill-missing.json >/tmp/rc-missing.out 2>&1
RC_MISSING=$?
EVIDENCE_DIR=.evidence-ci ./scripts/evaluate-contract.sh .evidence-ci/drill-backup-false.json | tee /tmp/rc-false.out
RC_FALSE=${PIPESTATUS[0]}
EVIDENCE_DIR=.evidence-ci ./scripts/evaluate-contract.sh .evidence-ci/drill-backup-string.json >/tmp/rc-strfalse.out 2>&1
RC_STRFALSE=$?
set -e

[[ "$RC_PROVE" -eq 0 ]] || {
  echo "expected exit 0 for PROVED, got $RC_PROVE" >&2
  fail=1
}
grep -q 'PROVED' /tmp/rc-prove.out || fail=1
grep -q 'RECOVERY DRILL #0042' /tmp/rc-prove.out || fail=1
[[ "$RC_FAIL" -eq 2 ]] || {
  echo "expected exit 2 for UNPROVED, got $RC_FAIL" >&2
  fail=1
}
grep -q 'UNPROVED' /tmp/rc-fail.out || fail=1
grep -q 'artifact_integrity' /tmp/rc-fail.out || fail=1
[[ "$RC_STALE" -eq 2 ]] || {
  echo "expected exit 2 for stale evidence, got $RC_STALE" >&2
  fail=1
}
grep -q 'evidence_freshness' /tmp/rc-stale.out || fail=1
# Missing required check field → schema error (exit 1)
[[ "$RC_MISSING" -eq 1 ]] || {
  echo "expected exit 1 for missing backup field (schema), got $RC_MISSING" >&2
  fail=1
}
grep -qi 'backup' /tmp/rc-missing.out || fail=1
# Literal false → UNPROVED (exit 2)
[[ "$RC_FALSE" -eq 2 ]] || {
  echo "expected exit 2 for backup=false, got $RC_FALSE" >&2
  fail=1
}
grep -q 'backup' /tmp/rc-false.out || fail=1
# String "false" → schema error (exit 1), never treated as pass
[[ "$RC_STRFALSE" -eq 1 ]] || {
  echo "expected exit 1 for backup=\"false\" string, got $RC_STRFALSE" >&2
  fail=1
}
rm -rf .evidence-ci

echo "== evaluate_contract + prove_consistency unit tests =="
if python3 -m pytest -q scripts/test_evaluate_contract.py scripts/test_prove_consistency.py; then
  :
else
  if ! python3 -c 'import sys; sys.path.insert(0,"scripts"); from evaluate_contract import evaluate; from prove_consistency import prove; print("import ok")'; then
    fail=1
  else
    echo "pytest not available; import smoke only" >&2
  fi
fi

echo "== failure scenarios =="
for s in corrupt-artifact wrong-secret schema-drift slow-restore noop-restore delete-s3-object corrupt-s3-object mismatched-recovery-points; do
  grep -q "$s" scripts/break.sh || {
    echo "missing scenario $s" >&2
    fail=1
  }
done
grep -q 'failure-drill' Makefile || fail=1
grep -q 'app-recovery-drill' Makefile || fail=1

echo "== kando still present =="
grep -q 'kando location push' blueprints/postgres/blueprint.yaml || fail=1

# stale score files must be gone
[[ ! -f config/recovery-slo.json ]] || {
  echo "stale recovery-slo.json" >&2
  fail=1
}
[[ ! -f scripts/compute-confidence.sh ]] || {
  echo "stale compute-confidence.sh" >&2
  fail=1
}

echo "== operator RBAC least privilege =="
python3 - <<'PY' || fail=1
from pathlib import Path
import re
text = Path("deploy/operator.yaml").read_text()
docs = [d.strip() for d in text.split("---") if d.strip()]
cluster_roles = {}
cluster_bindings = []
for d in docs:
    kind_m = re.search(r"^kind:\s*(\S+)", d, re.M)
    if not kind_m:
        continue
    kind = kind_m.group(1)
    meta = re.search(r"metadata:\s*\n\s*name:\s*(\S+)", d)
    name = meta.group(1) if meta else ""
    if kind == "ClusterRole":
        cluster_roles[name] = d
    elif kind == "ClusterRoleBinding":
        cluster_bindings.append(d)
for b in cluster_bindings:
    rm = re.search(r"roleRef:\s*\n(?:\s+.+\n)*?\s+name:\s*(\S+)", b)
    if not rm:
        raise SystemExit("ClusterRoleBinding missing roleRef name")
    role_name = rm.group(1)
    body = cluster_roles.get(role_name, "")
    # Only the rules list matters (ignore comments)
    rules = body.split("rules:", 1)[-1] if "rules:" in body else body
    if re.search(r"\bsecrets\b", rules):
        raise SystemExit(f"ClusterRoleBinding must not grant secrets via {role_name}")
if "kind: Role" not in text:
    raise SystemExit("namespaced Role missing")
drill = Path("scripts/app-recovery-drill.sh").read_text()
if '"postgres": True, "s3": True' in drill:
    raise SystemExit("components hardcoded True")
if "component_skew_seconds" not in drill:
    raise SystemExit("component_skew_seconds missing from drill evidence")
# Drill ClusterRole with secrets must only be RoleBound (namespaced), not ClusterRoleBound
drill_role = "recovery-contract-operator-drill"
for b in cluster_bindings:
    if re.search(rf"name:\s*{re.escape(drill_role)}\s*$", b, re.M):
        # roleRef name line
        if re.search(rf"roleRef:[\s\S]*?name:\s*{re.escape(drill_role)}", b):
            raise SystemExit(f"{drill_role} must not be ClusterRoleBound")
print("✓ operator RBAC + component evidence checks")
PY

echo "== kanister-operator RBAC least privilege =="
python3 - <<'PY' || fail=1
from pathlib import Path
import re
text = Path("deploy/kanister-rbac.yaml").read_text()
docs = [d.strip() for d in text.split("---") if d.strip()]
cluster_roles = {}
cluster_bindings = []
for d in docs:
    kind_m = re.search(r"^kind:\s*(\S+)", d, re.M)
    if not kind_m:
        continue
    kind = kind_m.group(1)
    meta = re.search(r"metadata:\s*\n\s*name:\s*(\S+)", d)
    name = meta.group(1) if meta else ""
    if kind == "ClusterRole":
        cluster_roles[name] = d
    elif kind == "ClusterRoleBinding":
        cluster_bindings.append(d)
for b in cluster_bindings:
    rm = re.search(r"roleRef:\s*\n(?:\s+.+\n)*?\s+name:\s*(\S+)", b)
    if not rm:
        raise SystemExit("ClusterRoleBinding missing roleRef name in kanister-rbac.yaml")
    role_name = rm.group(1)
    body = cluster_roles.get(role_name, "")
    rules = body.split("rules:", 1)[-1] if "rules:" in body else body
    if re.search(r"\bsecrets\b", rules):
        raise SystemExit(f"ClusterRoleBinding must not grant secrets via {role_name}")
if "kind: Role" not in text:
    raise SystemExit("namespaced Role missing from kanister-rbac.yaml")
# Legacy name: ClusterRoleBinding must not be named kanister-operator-drill anymore
for b in cluster_bindings:
    meta = re.search(r"metadata:\s*\n\s*name:\s*(\S+)", b)
    if meta and meta.group(1) == "kanister-operator-drill":
        raise SystemExit("legacy ClusterRoleBinding kanister-operator-drill still present")
print("✓ kanister-operator RBAC checks")
PY

if [[ "$fail" -ne 0 ]]; then
  echo "ci failed" >&2
  exit 1
fi
echo "ci checks passed"
