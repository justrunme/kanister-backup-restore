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

[[ -n "$SCENARIO" ]] || { usage; exit 1; }

case "$SCENARIO" in
  reset)
    rm -f "$STATE_FILE"
    echo "break state cleared"
    exit 0
    ;;
  corrupt-artifact)
    FROM="$(kubectl -n "$PROFILE_NS" get actionsets -l justrunme.com/phase=backup --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
    [[ -n "$FROM" ]] || { echo "no backup ActionSet — run backup-drill first" >&2; exit 1; }
    LOC="$(kubectl -n "$PROFILE_NS" get "actionset/${FROM}" -o jsonpath='{.status.actions[0].artifacts.cloudObject.keyValue.backupLocation}')"
    [[ -n "$LOC" ]] || { echo "empty backupLocation" >&2; exit 1; }
    # Overwrite object with garbage via MinIO mc
    kubectl -n "$PROFILE_NS" delete job break-corrupt-artifact --ignore-not-found
    cat <<YAML | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: break-corrupt-artifact
  namespace: ${PROFILE_NS}
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: minio/mc:RELEASE.2024-11-17T19-35-46Z
          env:
            - name: ACCESS_KEY
              valueFrom: { secretKeyRef: { name: minio-creds, key: access_key } }
            - name: SECRET_KEY
              valueFrom: { secretKeyRef: { name: minio-creds, key: secret_key } }
            - name: OBJECT
              value: "drills/${LOC}"
          command: ["/bin/sh","-c"]
          args:
            - |
              set -euo pipefail
              export MC_HOST_local="http://\${ACCESS_KEY}:\${SECRET_KEY}@minio.kanister.svc.cluster.local:9000"
              # Path in Profile uses prefix drills/ + backupLocation
              KEY="kanister-drills/drills/${LOC}"
              # Prefer exact key layout used by kando (bucket/prefix/path)
              echo "corrupting object for ${LOC}"
              printf 'NOT-A-GZIP-ARTIFACT' | mc pipe "local/kanister-drills/drills/${LOC}" || \
                printf 'NOT-A-GZIP-ARTIFACT' | mc pipe "local/kanister-drills/${LOC}"
              echo "corrupt-artifact applied"
YAML
    kubectl -n "$PROFILE_NS" wait --for=condition=complete job/break-corrupt-artifact --timeout=120s
    cat > "$STATE_FILE" <<EOF
BREAK_SCENARIO=corrupt-artifact
BREAK_BACKUP_ACTIONSET=${FROM}
BREAK_BACKUP_LOCATION=${LOC}
EXPECTED_BLOCKED_AT=validate
EOF
    echo "scenario corrupt-artifact armed (validate should FAIL)"
    ;;
  wrong-secret)
    cat > "$STATE_FILE" <<EOF
BREAK_SCENARIO=wrong-secret
EXPECTED_BLOCKED_AT=restore
BREAK_BAD_PASSWORD=definitely-wrong-password
EOF
    echo "scenario wrong-secret armed (restore auth should FAIL)"
    ;;
  schema-drift)
    cat > "$STATE_FILE" <<EOF
BREAK_SCENARIO=schema-drift
EXPECTED_BLOCKED_AT=verify
EOF
    echo "scenario schema-drift armed (data verification should FAIL)"
    ;;
  slow-restore)
    cat > "$STATE_FILE" <<EOF
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
