#!/usr/bin/env bash
# Signed S3 helpers against the in-cluster store, from the CI runner.
# Avoids in-cluster Jobs: weed shell is a REPL and never exits.
# Usage:
#   s3-object.sh ensure-bucket
#   s3-object.sh put <object-key> <file>
#   s3-object.sh get <object-key> <file>
#   s3-object.sh head <object-key>
#   s3-object.sh delete <object-key>
#   s3-object.sh copy <src-key> <dst-key>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${KANISTER_NAMESPACE:-kanister}"
SVC="${S3_SERVICE:-seaweedfs}"
SVC_PORT="${S3_SERVICE_PORT:-8333}"
LOCAL_PORT="${S3_LOCAL_PORT:-18333}"
BUCKET="${S3_BUCKET:-kanister-drills}"
ACCESS_KEY="${S3_ACCESS_KEY:-admin}"
SECRET_KEY="${S3_SECRET_KEY:-admin12345}"
REGION="${S3_REGION:-us-east-1}"
ACTION="${1:-}"

usage() {
  echo "Usage: $0 ensure-bucket | put <key> <file> | get <key> <file> | head <key> | delete <key> | copy <src> <dst>" >&2
  exit 1
}

[[ -n "$ACTION" ]] || usage

export S3_LOCAL_PORT="$LOCAL_PORT" S3_BUCKET="$BUCKET" S3_ACCESS_KEY="$ACCESS_KEY" S3_SECRET_KEY="$SECRET_KEY" S3_REGION="$REGION"

PF_PID=""
cleanup() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

start_port_forward() {
  kubectl -n "$NS" port-forward "svc/${SVC}" "${LOCAL_PORT}:${SVC_PORT}" >/tmp/s3-pf.log 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 40); do
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      echo "port-forward exited:" >&2
      cat /tmp/s3-pf.log >&2 || true
      return 1
    fi
    if python3 - "$LOCAL_PORT" <<'PY'; then
import socket, sys
s = socket.socket()
s.settimeout(0.4)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
s.close()
PY
      return 0
    fi
    sleep 0.25
  done
  echo "port-forward did not become ready" >&2
  cat /tmp/s3-pf.log >&2 || true
  return 1
}

s3_request_bucket() {
  local method="$1"
  python3 - "$method" "$LOCAL_PORT" "$BUCKET" "$ACCESS_KEY" "$SECRET_KEY" "$REGION" <<'PY'
import hashlib, hmac, datetime, sys, urllib.request, urllib.error
method, port, bucket, access, secret, region = sys.argv[1:7]
host = f"127.0.0.1:{port}"
uri = f"/{bucket}"
body = b""
now = datetime.datetime.now(datetime.timezone.utc)
amzdate = now.strftime("%Y%m%dT%H%M%SZ")
datestamp = now.strftime("%Y%m%d")
payload_hash = hashlib.sha256(body).hexdigest()
canonical_headers = f"host:{host}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amzdate}\n"
signed_headers = "host;x-amz-content-sha256;x-amz-date"
canonical_request = "\n".join([method, uri, "", canonical_headers, signed_headers, payload_hash])
scope = f"{datestamp}/{region}/s3/aws4_request"
string_to_sign = "\n".join(["AWS4-HMAC-SHA256", amzdate, scope, hashlib.sha256(canonical_request.encode()).hexdigest()])

def _sign(key, msg):
    return hmac.new(key, msg.encode() if isinstance(msg, str) else msg, hashlib.sha256).digest()

k = _sign(("AWS4" + secret).encode(), datestamp)
k = _sign(k, region)
k = _sign(k, "s3")
k = _sign(k, "aws4_request")
signature = hmac.new(k, string_to_sign.encode(), hashlib.sha256).hexdigest()
auth = f"AWS4-HMAC-SHA256 Credential={access}/{scope}, SignedHeaders={signed_headers}, Signature={signature}"
req = urllib.request.Request(
    f"http://{host}{uri}",
    data=None,
    method=method,
    headers={"Host": host, "x-amz-date": amzdate, "x-amz-content-sha256": payload_hash, "Authorization": auth},
)
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        print(f"{method} {uri} -> {resp.status}")
        sys.exit(0)
except urllib.error.HTTPError as e:
    detail = e.read().decode("utf-8", "replace")[:500]
    print(f"{method} {uri} -> {e.code} {detail}", file=sys.stderr)
    if e.code in (200, 204, 409):
        sys.exit(0)
    sys.exit(1)
PY
}

start_port_forward

case "$ACTION" in
  ensure-bucket)
    s3_request_bucket PUT
    s3_request_bucket HEAD
    echo "bucket ${BUCKET} ready (HeadBucket ok)"
    ;;
  put | get | head | delete | copy)
    shift
    python3 "$ROOT/scripts/s3-client.py" "$ACTION" "$@"
    ;;
  *)
    usage
    ;;
esac
