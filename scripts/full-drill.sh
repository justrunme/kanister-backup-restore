#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== full drill: install plane -> backup -> validate -> restore =="
"$ROOT/scripts/kind-up.sh"
"$ROOT/scripts/install-kanister.sh"
"$ROOT/scripts/minio.sh"
"$ROOT/scripts/apply-blueprints.sh"
"$ROOT/scripts/backup-drill.sh"
"$ROOT/scripts/validate-backup.sh"
"$ROOT/scripts/restore-drill.sh"
"$ROOT/scripts/collect-evidence.sh"
echo "full drill OK"
