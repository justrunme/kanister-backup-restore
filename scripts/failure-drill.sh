#!/usr/bin/env bash
# Arm a failure scenario, then run the Recovery Contract drill.
# Usage: failure-drill.sh SCENARIO=corrupt-artifact
#    or: failure-drill.sh corrupt-artifact
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW="${1:-${SCENARIO:-}}"
# Accept SCENARIO=name from make: make failure-drill SCENARIO=corrupt-artifact
if [[ "$RAW" == SCENARIO=* ]]; then
  SCENARIO="${RAW#SCENARIO=}"
else
  SCENARIO="$RAW"
fi

case "$SCENARIO" in
  corrupt-artifact|wrong-secret|schema-drift|slow-restore) ;;
  ""|help|-h|--help)
    cat <<EOF
Usage: make failure-drill SCENARIO=<name>

Scenarios:
  corrupt-artifact  VALIDATE fails · Restore BLOCKED · UNPROVED
  wrong-secret      RESTORE fails · UNPROVED
  schema-drift      DATA VERIFY fails · UNPROVED
  slow-restore      RTO exceeds contract · UNPROVED
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
"$ROOT/scripts/recovery-drill.sh"
