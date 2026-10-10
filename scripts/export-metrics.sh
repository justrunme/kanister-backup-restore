#!/usr/bin/env bash
# Export Recovery Contract metrics in Prometheus format
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/.evidence}"
LATEST_EVIDENCE="${LATEST_EVIDENCE:-$EVIDENCE_DIR/recovery-verdict.json}"
METRICS_DIR="${METRICS_DIR:-$ROOT/.metrics}"
PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-}"

mkdir -p "$METRICS_DIR"

if [[ ! -f "$LATEST_EVIDENCE" ]]; then
  echo "No evidence found at $LATEST_EVIDENCE" >&2
  echo "Run 'make full-drill' first" >&2
  exit 1
fi

METRICS_FILE="$METRICS_DIR/recovery-contract.prom"

python3 - "$LATEST_EVIDENCE" "$METRICS_FILE" <<'PY'
import json, sys, pathlib
from datetime import datetime, timezone

evidence_path, metrics_path = sys.argv[1:3]
ev = json.loads(pathlib.Path(evidence_path).read_text())

verdict = ev.get("verdict", "UNPROVED")
verdict_numeric = 1 if verdict == "PROVED" else 0

metrics = ev.get("metrics", {})
rto_seconds = metrics.get("rto_seconds")
evidence_age_hours = metrics.get("evidence_age_hours", 0)
drill_id = ev.get("drill_id", 0)
scenario = ev.get("scenario", "unknown")

lines = [
    "# HELP recovery_contract_verdict Recovery Contract verdict (1=PROVED, 0=UNPROVED)",
    "# TYPE recovery_contract_verdict gauge",
    f'recovery_contract_verdict{{scenario="{scenario}",verdict="{verdict}"}} {verdict_numeric}',
    "",
]

if rto_seconds is not None:
    lines += [
        "# HELP recovery_rto_seconds Recovery Time Objective in seconds",
        "# TYPE recovery_rto_seconds gauge",
        f'recovery_rto_seconds{{scenario="{scenario}"}} {rto_seconds}',
        "",
    ]

lines += [
    "# HELP recovery_evidence_age_hours Age of recovery evidence in hours",
    "# TYPE recovery_evidence_age_hours gauge",
    f'recovery_evidence_age_hours{{scenario="{scenario}"}} {evidence_age_hours}',
    "",
    "# HELP recovery_drill_id Sequential drill identifier",
    "# TYPE recovery_drill_id counter",
    f'recovery_drill_id{{scenario="{scenario}"}} {drill_id}',
    "",
]

pathlib.Path(metrics_path).write_text("\n".join(lines))
print(f"wrote {metrics_path}")
PY

cat "$METRICS_FILE"

if [[ -n "$PUSHGATEWAY_URL" ]]; then
  echo ""
  echo "Pushing to Pushgateway at $PUSHGATEWAY_URL"
  curl -X POST --data-binary @"$METRICS_FILE" \
    "$PUSHGATEWAY_URL/metrics/job/recovery-contract/instance/$(hostname -f 2>/dev/null || hostname)" \
    -H "Content-Type: text/plain" || {
    echo "Failed to push to Pushgateway" >&2
    exit 1
  }
  echo "Metrics pushed successfully"
fi
