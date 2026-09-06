#!/usr/bin/env bash
# Evaluate drill evidence against the Recovery Contract.
# Verdict: PROVED | UNPROVED (binary — never a percentage).
# Usage: evaluate-contract.sh [evidence.json]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="${1:-}"
CFG_JSON="$ROOT/config/recovery-contract.json"
OUT_DIR="${EVIDENCE_DIR:-$ROOT/.evidence}"
mkdir -p "$OUT_DIR"

if [[ -z "$IN" ]]; then
  IN="$(ls -1t "$OUT_DIR"/drill-*.json 2>/dev/null | head -1 || true)"
fi
if [[ -z "$IN" || ! -f "$IN" ]]; then
  echo "No evidence JSON found. Run a drill first (make recovery-drill)." >&2
  exit 1
fi

python3 - "$IN" "$CFG_JSON" "$OUT_DIR" <<'PY'
import json, sys, pathlib
from datetime import datetime, timezone

evidence_path, cfg_path, out_dir = sys.argv[1:4]
ev = json.loads(pathlib.Path(evidence_path).read_text())
cfg = json.loads(pathlib.Path(cfg_path).read_text())
contract = cfg["contract"]

checks = ev.get("checks", {})
metrics = ev.get("metrics", {})

backup_ok = bool(checks.get("backup", True))
artifact_ok = bool(checks.get("artifact_integrity"))
restore_ok = bool(checks.get("restore_completed"))
app_ok = bool(checks.get("application_health"))
data_ok = bool(checks.get("data_verification"))
rto = metrics.get("rto_seconds")
rto_max = int(contract["rto_seconds_max"])
rto_ok = restore_ok and rto is not None and rto <= rto_max
age_h = metrics.get("evidence_age_hours", 0)
age_max = int(contract["evidence_freshness_hours_max"])
fresh_ok = age_h is not None and float(age_h) <= age_max

# Ordered contract clauses — first failure becomes Reason
clauses = [
    ("backup", backup_ok, "required"),
    ("artifact_integrity", artifact_ok, "required"),
    ("isolated_restore", restore_ok, "required"),
    ("application_ready", app_ok, "required"),
    ("data_verification", data_ok, "required"),
    ("rto", rto_ok, f"< {rto_max}s"),
    ("evidence_freshness", fresh_ok, f"< {age_max}h"),
]

reason = None
for name, ok, _ in clauses:
    if not ok:
        reason = name
        break

verdict = "PROVED" if reason is None else "UNPROVED"
blocked = ev.get("blocked_at") or None
drill_id = ev.get("drill_id") or metrics.get("drill_id") or 0
scenario = ev.get("scenario", "happy-path")

def fmt_duration(seconds):
    if seconds is None:
        return "—"
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    m, s = divmod(seconds, 60)
    if m < 60:
        return f"{m}m {s:02d}s"
    h, m = divmod(m, 60)
    return f"{h}h {m}m"

def fmt_age_minutes(hours):
    if hours is None:
        return "—"
    mins = int(float(hours) * 60)
    if mins <= 0:
        return "0m"
    if mins < 60:
        return f"{mins}m"
    h, m = divmod(mins, 60)
    return f"{h}h {m}m"

rpo_s = metrics.get("rpo_seconds")
rto_s = rto
evidence_age = fmt_age_minutes(age_h)

results = {
    "Backup": "PASS" if backup_ok else "FAIL",
    "Artifact integrity": "PASS" if artifact_ok else "FAIL",
    "Isolated restore": (
        "PASS" if restore_ok else ("BLOCKED" if blocked in ("validate", None) and not artifact_ok else "FAIL")
    ),
    "Application ready": (
        "PASS" if app_ok else ("—" if not restore_ok else "FAIL")
    ),
    "Recovery marker": (
        "PASS" if data_ok else ("—" if not restore_ok else "FAIL")
    ),
}

# If blocked at validate, restore shows BLOCKED
if blocked == "validate" or (not artifact_ok and not restore_ok):
    results["Isolated restore"] = "BLOCKED"
    results["Application ready"] = "—"
    results["Recovery marker"] = "—"

report = {
    "concept": "Recovery Contract",
    "tagline": cfg.get("tagline", "Restore should be proved, not assumed."),
    "lifecycle": cfg.get("lifecycle"),
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source_evidence": str(evidence_path),
    "drill_id": drill_id,
    "scenario": scenario,
    "verdict": verdict,
    "reason": reason,
    "blocked_at": blocked,
    "contract": contract,
    "results": results,
    "metrics": {
        "rpo_seconds": rpo_s,
        "rto_seconds": rto_s,
        "rto_max_seconds": rto_max,
        "evidence_age_hours": age_h,
        "evidence_freshness_hours_max": age_max,
        "backup_actionset": ev.get("backup_actionset"),
        "restore_actionset": ev.get("restore_actionset"),
        "drill_namespace": ev.get("drill_namespace"),
        "backup_location": ev.get("backup_location"),
    },
    "clauses": [
        {"name": n, "ok": ok, "requirement": req} for n, ok, req in clauses
    ],
}

out_json = pathlib.Path(out_dir) / "recovery-verdict.json"
out_md = pathlib.Path(out_dir) / "recovery-verdict.md"
out_json.write_text(json.dumps(report, indent=2) + "\n")

lines = [
    f"# Recovery Drill #{int(drill_id):04d}",
    "",
    f"**{report['tagline']}**",
    "",
    f"- Verdict: **{verdict}**",
    f"- Scenario: `{scenario}`",
]
if reason:
    lines.append(f"- Reason: `{reason}`")
lines += ["", "## Results", ""]
for k, v in results.items():
    lines.append(f"- {k}: {v}")
lines += [
    "",
    f"- RPO: {fmt_duration(rpo_s)}",
    f"- RTO: {fmt_duration(rto_s)}",
    f"- Evidence age: {evidence_age}",
    "",
    "## Recovery Contract",
    "",
]
for n, ok, req in clauses:
    lines.append(f"- {n}: {req} → {'PASS' if ok else 'FAIL'}")
lines += ["", f"**RECOVERY {verdict}**", ""]
out_md.write_text("\n".join(lines) + "\n")

# Console card
id4 = f"{int(drill_id):04d}"
w = 44
print("┌" + "─" * w + "┐")
print(f"│  RECOVERY DRILL #{id4:<32}│")
print("├" + "─" * w + "┤")
for label, val in results.items():
    print(f"│  {label:<22} {val:<19}│")
print("├" + "─" * w + "┤")
print(f"│  {'RPO':<22} {fmt_duration(rpo_s):<19}│")
print(f"│  {'RTO':<22} {fmt_duration(rto_s):<19}│")
print(f"│  {'Evidence age':<22} {evidence_age:<19}│")
print("├" + "─" * w + "┤")
print(f"│  {'RECOVERY':<22} {verdict:<19}│")
if reason:
    print(f"│  {'Reason':<22} {reason:<19}│")
print("└" + "─" * w + "┘")
print(f"wrote {out_json}")
print(f"wrote {out_md}")
sys.exit(0)
PY
