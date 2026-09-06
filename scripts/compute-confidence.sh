#!/usr/bin/env bash
# Deterministic Recovery Confidence + Recovery SLO from drill evidence JSON.
# Usage: compute-confidence.sh [evidence.json]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="${1:-}"
CFG="$ROOT/config/recovery-slo.yaml"
OUT_DIR="${EVIDENCE_DIR:-$ROOT/.evidence}"
mkdir -p "$OUT_DIR"

if [[ -z "$IN" ]]; then
  IN="$(ls -1t "$OUT_DIR"/drill-*.json 2>/dev/null | head -1 || true)"
fi
if [[ -z "$IN" || ! -f "$IN" ]]; then
  echo "No evidence JSON found. Run a drill first (make recovery-drill)." >&2
  exit 1
fi

python3 - "$IN" "$CFG" "$OUT_DIR" <<'PY'
import json, sys, pathlib
from datetime import datetime, timezone

evidence_path, cfg_path, out_dir = sys.argv[1:4]
ev = json.loads(pathlib.Path(evidence_path).read_text())
# Minimal YAML subset parser for our config (no PyYAML dependency)
cfg_text = pathlib.Path(cfg_path).read_text().splitlines()

def parse_simple_yaml(lines):
    root = {}
    stack = [(0, root)]
    for raw in lines:
        if not raw.strip() or raw.strip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        line = raw.strip()
        while stack and indent < stack[-1][0]:
            stack.pop()
        cur = stack[-1][1]
        if line.endswith(":") and ":" == line[-1] and line.count(":") == 1:
            key = line[:-1].strip()
            nxt = {}
            if isinstance(cur, list):
                raise SystemExit("unexpected list context")
            cur[key] = nxt
            stack.append((indent + 2, nxt))
            continue
        if line.startswith("- "):
            # treat as list of scalars under previous key — skip complex
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            if v == "":
                cur[k] = {}
                stack.append((indent + 2, cur[k]))
            else:
                if v.lower() in ("true", "false"):
                    cur[k] = v.lower() == "true"
                else:
                    try:
                        cur[k] = int(v) if "." not in v else float(v)
                    except ValueError:
                        cur[k] = v
    return root

# Prefer json twin if present
cfg_json = pathlib.Path(cfg_path).with_suffix(".json")
if cfg_json.exists():
    cfg = json.loads(cfg_json.read_text())
else:
    # fallback hardcoded weights matching recovery-slo.yaml
    cfg = {
        "weights": {
            "artifact_integrity": 20,
            "restore_completed": 25,
            "application_health": 20,
            "data_verification": 20,
            "rto_within_target": 10,
            "evidence_fresh": 5,
        },
        "slo": {
            "rto_p95_seconds": 60,
            "evidence_max_age_hours": 24,
        },
        "freshness": {"evidence_fresh_hours": 24},
    }

w = cfg["weights"]
checks = {
    "artifact_integrity": bool(ev.get("checks", {}).get("artifact_integrity")),
    "restore_completed": bool(ev.get("checks", {}).get("restore_completed")),
    "application_health": bool(ev.get("checks", {}).get("application_health")),
    "data_verification": bool(ev.get("checks", {}).get("data_verification")),
    "rto_within_target": bool(ev.get("checks", {}).get("rto_within_target")),
    "evidence_fresh": bool(ev.get("checks", {}).get("evidence_fresh", True)),
}

score = sum(w[k] for k, ok in checks.items() if ok)
max_score = sum(w.values())

# State machine (highest attained)
order = [
    ("PROVED", ["artifact_integrity", "restore_completed", "application_health", "data_verification", "rto_within_target", "evidence_fresh"]),
    ("VERIFIED", ["artifact_integrity", "restore_completed", "application_health", "data_verification"]),
    ("RESTORED", ["artifact_integrity", "restore_completed"]),
    ("VALIDATED", ["artifact_integrity"]),
    ("UNPROVEN", []),
]
state = "UNPROVEN"
for name, need in order:
    if all(checks[k] for k in need):
        state = name
        break

rto = ev.get("metrics", {}).get("rto_seconds")
rto_target = cfg.get("slo", {}).get("rto_p95_seconds", 60)
evidence_age_h = ev.get("metrics", {}).get("evidence_age_hours", 0)
evidence_target = cfg.get("slo", {}).get("evidence_max_age_hours", 24)

slo_checks = {
    "restore_success": checks["restore_completed"] and checks["artifact_integrity"],
    "rto_within_target": checks["rto_within_target"],
    "evidence_fresh": evidence_age_h <= evidence_target if evidence_age_h is not None else False,
    "artifact_integrity": checks["artifact_integrity"],
    "data_verification": checks["data_verification"],
}
slo_met = all(slo_checks.values())

report = {
    "concept": "Continuous Recovery Confidence",
    "tagline": "Restore should be proved, not assumed.",
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source_evidence": str(evidence_path),
    "state": state,
    "confidence": {"score": score, "max": max_score, "percent": score},
    "checks": checks,
    "weights": w,
    "metrics": {
        "rto_seconds": rto,
        "rto_target_seconds": rto_target,
        "evidence_age_hours": evidence_age_h,
        "evidence_max_age_hours": evidence_target,
        "backup_actionset": ev.get("backup_actionset"),
        "restore_actionset": ev.get("restore_actionset"),
        "drill_namespace": ev.get("drill_namespace"),
        "backup_location": ev.get("backup_location"),
        "scenario": ev.get("scenario", "happy-path"),
    },
    "recovery_slo": {
        "status": "MET" if slo_met else "BREACHED",
        "checks": slo_checks,
    },
}

out_json = pathlib.Path(out_dir) / "recovery-confidence.json"
out_md = pathlib.Path(out_dir) / "recovery-confidence.md"
out_json.write_text(json.dumps(report, indent=2) + "\n")

def mark(ok):
    return "PASS" if ok else "FAIL"

lines = [
    "# Recovery Confidence",
    "",
    f"**{report['tagline']}**",
    "",
    f"- State: `{state}`",
    f"- Confidence: **{score} / {max_score}**",
    f"- Recovery SLO: **{report['recovery_slo']['status']}**",
    f"- Scenario: `{report['metrics']['scenario']}`",
    "",
    "## Checks",
    "",
    f"| Check | Weight | Result |",
    f"|---|---:|---|",
]
for k, weight in w.items():
    lines.append(f"| {k} | {weight} | {mark(checks[k])} |")
lines += [
    "",
    "## Recovery SLO",
    "",
    f"| Signal | Target | Result |",
    f"|---|---|---|",
    f"| Restore success | required | {mark(slo_checks['restore_success'])} |",
    f"| RTO | < {rto_target}s (observed {rto if rto is not None else 'n/a'}s) | {mark(slo_checks['rto_within_target'])} |",
    f"| Evidence age | < {evidence_target}h (observed {evidence_age_h}h) | {mark(slo_checks['evidence_fresh'])} |",
    f"| Artifact integrity | PASS | {mark(slo_checks['artifact_integrity'])} |",
    f"| Data verification | PASS | {mark(slo_checks['data_verification'])} |",
    "",
    f"STATUS: **RECOVERY {'PROVED' if state == 'PROVED' else state}** · confidence {score}%",
    "",
]
out_md.write_text("\n".join(lines))

# Human console card
print("┌──────────────────────────────────────────┐")
print("│  RECOVERY CONFIDENCE                     │")
print(f"│  State           {state:<24} │")
print(f"│  Confidence      {score:>3} / {max_score:<18} │")
print(f"│  Recovery SLO    {report['recovery_slo']['status']:<24} │")
print(f"│  Scenario        {str(report['metrics']['scenario']):<24} │")
print("├──────────────────────────────────────────┤")
for k, weight in w.items():
    print(f"│  {k:<22} {mark(checks[k]):<4} (+{weight:<2}) │")
print("├──────────────────────────────────────────┤")
print(f"│  RTO {rto if rto is not None else '-':>6}s   target <{rto_target}s          │")
print("└──────────────────────────────────────────┘")
print(f"wrote {out_json}")
print(f"wrote {out_md}")
# Always succeed as a reporter; callers decide pass/fail from state/SLO fields.
sys.exit(0)
PY
