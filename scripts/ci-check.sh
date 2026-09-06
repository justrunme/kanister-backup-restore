#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

echo "== required files =="
for f in \
  README.md LICENSE Makefile \
  blueprints/postgres/blueprint.yaml \
  blueprints/generic-pvc/blueprint.yaml \
  deploy/minio-profile.yaml \
  deploy/cronjob-backup-drill.yaml \
  examples/postgres-statefulset.yaml \
  scripts/run-action.sh \
  scripts/full-drill.sh \
  scripts/collect-evidence.sh
do
  [[ -f "$f" ]] || { echo "missing $f" >&2; fail=1; }
done

echo "== yaml skeletons =="
while IFS= read -r -d '' f; do
  grep -q 'apiVersion:' "$f" && grep -q 'kind:' "$f" || { echo "bad yaml $f" >&2; fail=1; }
done < <(find blueprints deploy examples -name '*.yaml' -print0)

echo "== postgres blueprint uses kando =="
grep -q 'kando location push' blueprints/postgres/blueprint.yaml || { echo "missing kando push" >&2; fail=1; }
grep -q 'kando location pull' blueprints/postgres/blueprint.yaml || { echo "missing kando pull" >&2; fail=1; }
grep -q 'gzip -t' blueprints/postgres/blueprint.yaml || { echo "missing gzip validate" >&2; fail=1; }

echo "== blueprint actions =="
for bp in blueprints/*/blueprint.yaml; do
  for action in backup validate restore delete; do
    grep -q "^  ${action}:" "$bp" || { echo "$bp missing $action" >&2; fail=1; }
  done
done

echo "== scripts shebang =="
for s in scripts/*.sh; do
  head -1 "$s" | grep -q '^#!' || { echo "no shebang $s" >&2; fail=1; }
done

echo "== tools image pinned =="
grep -q 'postgres-kanister-tools:0.118.0' blueprints/postgres/blueprint.yaml || fail=1

if [[ "$fail" -ne 0 ]]; then
  echo "ci failed" >&2
  exit 1
fi
echo "ci checks passed"
