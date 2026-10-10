#!/usr/bin/env bash
# Inject failure modes that make a backup untrustworthy.
# Usage: break.sh <scenario>
#   corrupt-artifact | wrong-secret | schema-drift | slow-restore | reset
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO="${1:-}"
PROFILE_NS="${PROFILE_NS:-kanister}"
STATE_FILE="${EVIDENCE_DIR:-$ROOT/.evidence}/active-break.env"
mkdir -p "$(dirname "$STATE_FILE")"

usage() {
  cat <<EOF
Usage: $0 <corrupt-artifact|wrong-secret|schema-drift|slow-restore|reset>

Scenarios prove which failure modes make recovery untrustworthy:
  corrupt-artifact  truncate object so VALIDATE fails (gzip)
  wrong-secret      bad DB password so RESTORE auth fails
  schema-drift      drop recovery_markers so DATA VERIFY fails
  slow-restore      sleep gate so RTO check fails
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
    FROM="$(kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
    [[ -n "$FROM" ]] || {
      echo "no backup ActionSet — run backup-drill first" >&2
      exit 1
    }
    LOC="$(kubectl -n "$PROFILE_NS" get "actionset/${FROM}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupLocation}')"
    [[ -n "$LOC" ]] || {
      echo "empty backupLocation" >&2
      exit 1
    }
    # Overwrite from the runner (SigV4). In-cluster Jobs that wait on a
    # service have hung this drill twice already.
    CORRUPT="$(mktemp)"
    printf 'NOT-A-GZIP-ARTIFACT' >"$CORRUPT"
    "$ROOT/scripts/s3-object.sh" put "drills/${LOC}" "$CORRUPT"
    rm -f "$CORRUPT"
    cat >"$STATE_FILE" <<EOF
BREAK_SCENARIO=corrupt-artifact
BREAK_BACKUP_ACTIONSET=${FROM}
BREAK_BACKUP_LOCATION=${LOC}
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
  *)
    usage
    exit 1
    ;;
esac
