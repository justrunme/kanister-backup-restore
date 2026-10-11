#!/usr/bin/env bash
# Arm a failure scenario, then run the Recovery Contract drill.
# Usage: failure-drill.sh SCENARIO=corrupt-artifact
#    or: failure-drill.sh corrupt-artifact
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="${1:-${SCENARIO:-}}"
if [[ "$RAW" == SCENARIO=* ]]; then
  SCENARIO="${RAW#SCENARIO=}"
else
  SCENARIO="$RAW"
fi

APP_SCENARIOS="delete-s3-object|corrupt-s3-object|mismatched-recovery-points"

case "$SCENARIO" in
  corrupt-artifact | wrong-secret | schema-drift | slow-restore | noop-restore | \
    delete-s3-object | corrupt-s3-object | mismatched-recovery-points) ;;
  "" | help | -h | --help)
    cat <<EOF
Usage: make failure-drill SCENARIO=<name>

Postgres-path:
  corrupt-artifact  VALIDATE fails · Restore BLOCKED · UNPROVED
  wrong-secret      RESTORE fails · UNPROVED
  schema-drift      DATA VERIFY fails · UNPROVED
  slow-restore      RTO exceeds contract · UNPROVED
  noop-restore      Restore no-op · DATA VERIFY fails · UNPROVED

Application (Postgres+S3):
  delete-s3-object              consistency UNPROVED
  corrupt-s3-object             consistency UNPROVED
  mismatched-recovery-points    consistency UNPROVED
EOF
    exit 1
    ;;
  *)
    echo "unknown scenario: $SCENARIO" >&2
    exit 1
    ;;
esac

chmod +x "$ROOT/scripts/"*.sh
"$ROOT/scripts/break.sh" "$SCENARIO"
if [[ "$SCENARIO" =~ ^($APP_SCENARIOS)$ ]]; then
  "$ROOT/scripts/app-recovery-drill.sh"
else
  # Postgres-only path still valid for marker/noop tests.
  "$ROOT/scripts/recovery-drill.sh"
fi
