#!/usr/bin/env bash
# Inject failure modes that make a backup untrustworthy.
# Usage: break.sh <scenario>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO="${1:-}"
STATE_FILE="${EVIDENCE_DIR:-$ROOT/.evidence}/active-break.env"
mkdir -p "$(dirname "$STATE_FILE")"

usage() {
  cat <<EOF
Usage: $0 <scenario|reset>

Postgres-path scenarios:
  corrupt-artifact  truncate object so VALIDATE fails (sha256/gzip)
  wrong-secret      bad DB password so RESTORE auth fails
  schema-drift      drop recovery_markers so DATA VERIFY fails
  slow-restore      sleep gate so RTO check fails
  noop-restore      restore ActionSet succeeds without applying data → UNPROVED

Application (Postgres+S3) scenarios:
  delete-s3-object              delete one RP object after backup → consistency UNPROVED
  corrupt-s3-object             corrupt one RP object after backup → consistency UNPROVED
  mismatched-recovery-points    mix RP-A postgres with RP-B S3 → consistency UNPROVED

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
  delete-s3-object)
    cat >"$STATE_FILE" <<EOF
BREAK_SCENARIO=delete-s3-object
EXPECTED_BLOCKED_AT=consistency
EOF
    echo "scenario delete-s3-object armed (consistency should FAIL)"
    ;;
  corrupt-s3-object)
    cat >"$STATE_FILE" <<EOF
BREAK_SCENARIO=corrupt-s3-object
EXPECTED_BLOCKED_AT=consistency
EOF
    echo "scenario corrupt-s3-object armed (consistency should FAIL)"
    ;;
  mismatched-recovery-points)
    cat >"$STATE_FILE" <<EOF
BREAK_SCENARIO=mismatched-recovery-points
EXPECTED_BLOCKED_AT=consistency
EOF
    echo "scenario mismatched-recovery-points armed (consistency should FAIL)"
    ;;
  *)
    usage
    exit 1
    ;;
esac
