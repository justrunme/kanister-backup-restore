#!/usr/bin/env bash
# Evaluate drill evidence against the Recovery Contract.
# Verdict: PROVED | UNPROVED (binary — never a percentage).
# Exit: 0 = PROVED, 2 = UNPROVED, 1 = error.
# Usage: evaluate-contract.sh [evidence.json]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="${1:-}"
CFG_JSON="$ROOT/config/recovery-contract.json"
OUT_DIR="${EVIDENCE_DIR:-$ROOT/.evidence}"
mkdir -p "$OUT_DIR"

if [[ -z "$IN" ]]; then
  IN="$(find "$OUT_DIR" -name 'drill-*.json' -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
fi
if [[ -z "$IN" || ! -f "$IN" ]]; then
  echo "No evidence JSON found. Run a drill first (make recovery-drill)." >&2
  exit 1
fi

# Prefer the Python module (real evidence age, fail-closed checks, exit gates).
python3 "$ROOT/scripts/evaluate_contract.py" "$IN" "$CFG_JSON" "$OUT_DIR"
