#!/usr/bin/env python3
import json, os, time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
verdict_path = root / ".evidence" / "recovery-verdict.json"
# Prefer happy-path drill metrics if latest is failure scenario
drills = sorted((root / ".evidence").glob("drill-*.json"))
happy = None
for p in drills:
    data = json.loads(p.read_text())
    if data.get("scenario") == "happy-path":
        happy = data
metrics = (happy or {}).get("metrics", {})
payload = {
    "repo": "kanister-backup-restore",
    "source_run": "https://github.com/%s/actions/runs/%s"
    % (os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_RUN_ID", "")),
    "measured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "metrics": {
        "rto_seconds": metrics.get("rto_seconds"),
        "component_skew_seconds": metrics.get("component_skew_seconds"),
        "scenario": (happy or {}).get("scenario", "unknown"),
        "checks": (happy or {}).get("checks", {}),
    },
}
if verdict_path.exists():
    v = json.loads(verdict_path.read_text())
    payload["latest_verdict"] = {"verdict": v.get("verdict"), "scenario": v.get("scenario"), "reason": v.get("reason")}
Path("docs/results.json").write_text(json.dumps(payload, indent=2) + "\n")
print(json.dumps(payload, indent=2))
