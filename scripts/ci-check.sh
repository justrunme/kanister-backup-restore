#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

echo "== check required files =="
for f in \
  README.md LICENSE Makefile \
  blueprints/postgres/blueprint.yaml \
  blueprints/generic-pvc/blueprint.yaml \
  profiles/s3-profile.example.yaml \
  examples/postgres-statefulset.yaml \
  scripts/backup-drill.sh \
  scripts/validate-backup.sh \
  scripts/restore-drill.sh
do
  if [[ ! -f "$f" ]]; then
    echo "missing $f" >&2
    fail=1
  fi
done

echo "== yaml structure (apiVersion/kind) =="
while IFS= read -r -d '' f; do
  if ! grep -q 'apiVersion:' "$f" || ! grep -q 'kind:' "$f"; then
    echo "invalid yaml skeleton: $f" >&2
    fail=1
  fi
done < <(find blueprints profiles examples deploy -name '*.yaml' -print0)

echo "== scripts executable bit / shebang =="
for s in scripts/*.sh; do
  if ! head -1 "$s" | grep -q '^#!'; then
    echo "missing shebang: $s" >&2
    fail=1
  fi
done

echo "== blueprint actions present =="
for bp in blueprints/*/blueprint.yaml; do
  for action in backup validate restore delete; do
    if ! grep -q "^  ${action}:" "$bp"; then
      echo "blueprint $bp missing action '$action'" >&2
      fail=1
    fi
  done
done

if [[ "$fail" -ne 0 ]]; then
  echo "ci checks failed" >&2
  exit 1
fi

echo "ci checks passed"
