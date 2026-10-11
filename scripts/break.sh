#!/usr/bin/env bash
# Inject failure modes that make a backup untrustworthy.
# Usage: break.sh <scenario>
#   corrupt-artifact | wrong-secret | schema-drift | slow-restore | noop-restore | reset
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO="${1:-}"
PROFILE_NS="${PROFILE_NS:-kanister}"
STATE_FILE="${EVIDENCE_DIR:-$ROOT/.evidence}/active-break.env"
mkdir -p "$(dirname "$STATE_FILE")"

usage() {
  cat <<EOF
Usage: $0 <corrupt-artifact|wrong-secret|schema-drift|slow-restore|noop-restore|reset>

Scenarios prove which failure modes make recovery untrustworthy:
  corrupt-artifact  truncate object so VALIDATE fails (sha256/gzip)
  wrong-secret      bad DB password so RESTORE auth fails
  schema-drift      drop recovery_markers so DATA VERIFY fails
  slow-restore      sleep gate so RTO check fails
  noop-restore      restore ActionSet succeeds without applying data → UNPROVED
  reset             clear active break state
EOF
}

[[ -n "$SCENARIO" ]] || {
  usage
  exit 1
}

case "$SCENARIO" in
  reset)
    rm -f "$STATE_FILE"
    echo "break state cleared"
    exit 0
    ;;
  corrupt-artifact)
    # Corruption is applied in recovery-drill.sh after the fresh backup so
    # the unique object key for this drill is the one that fails VALIDATE.
    cat >"$STATE_FILE" <<EOF
BREAK_SCENARIO=corrupt-artifact
EXPECTED_BLOCKED_AT=validate
EOF
    echo "scenario corrupt-artifact armed (validate should FAIL)"
    ;;
  wrong-secret)
    cat >"$STATE_FILE" <<EOF
BREAK_SCENARIO=wrong-secret
EXPECTED_BLOCKED_AT=restore
BREAK_BAD_PASSWORD=definitely-wrong-password
EOF
    echo "scenario wrong-secret armed (restore auth should FAIL)"
    ;;
  schema-drift)
    cat >"$STATE_FILE" <<EOF
BREAK_SCENARIO=schema-drift
EXPECTED_BLOCKED_AT=verify
EOF
    echo "scenario schema-drift armed (data verification should FAIL)"
    ;;
  slow-restore)
    cat >"$STATE_FILE" <<EOF
BREAK_SCENARIO=slow-restore
EXPECTED_BLOCKED_AT=rto
BREAK_RTO_SLEEP_SECONDS=75
EOF
    echo "scenario slow-restore armed (RTO should BREACH target)"
    ;;
  noop-restore)
    cat >"$STATE_FILE" <<EOF
BREAK_SCENARIO=noop-restore
EXPECTED_BLOCKED_AT=verify
EOF
    echo "scenario noop-restore armed (data verification should FAIL)"
    ;;
  *)
    usage
    exit 1
    ;;
esac
