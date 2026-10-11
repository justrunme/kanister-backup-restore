#!/usr/bin/env python3
"""Evaluate drill evidence against the Recovery Contract.

Verdict is binary: PROVED | UNPROVED.
Exit codes: 0 = PROVED, 2 = UNPROVED, 1 = usage/input error.
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


# Minimal JSON Schema (draft-07 subset) for drill evidence.
# Validated by validate_evidence() without an external jsonschema dependency.
EVIDENCE_SCHEMA: dict[str, Any] = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "type": "object",
    "required": ["drill_id", "scenario", "collected_at", "checks", "metrics"],
    "properties": {
        "drill_id": {"type": "integer"},
        "scenario": {"type": "string", "minLength": 1},
        "blocked_at": {"type": ["string", "null"]},
        "backup_actionset": {"type": ["string", "null"]},
        "restore_actionset": {"type": ["string", "null"]},
        "drill_namespace": {"type": ["string", "null"]},
        "backup_location": {"type": ["string", "null"]},
        "collected_at": {"type": "string", "minLength": 1},
        "checks": {
            "type": "object",
            "required": [
                "backup",
                "artifact_integrity",
                "restore_completed",
                "application_health",
                "data_verification",
            ],
            "properties": {
                "backup": {"type": "boolean"},
                "artifact_integrity": {"type": "boolean"},
                "restore_completed": {"type": "boolean"},
                "application_health": {"type": "boolean"},
                "data_verification": {"type": "boolean"},
                "cross_component_consistency": {"type": "boolean"},
                "rto_within_target": {"type": "boolean"},
                "evidence_fresh": {"type": "boolean"},
            },
            "additionalProperties": True,
        },
        "components": {
            "type": "object",
            "properties": {
                "postgres": {"type": "boolean"},
                "s3": {"type": "boolean"},
            },
            "additionalProperties": True,
        },
        "metrics": {
            "type": "object",
            "required": ["rto_seconds"],
            "properties": {
                "rpo_seconds": {"type": ["integer", "null"]},
                "rto_seconds": {"type": ["integer", "null"]},
                "rto_target_seconds": {"type": ["integer", "null"]},
                "evidence_age_hours": {"type": ["number", "null"]},
                "drill_id": {"type": "integer"},
            },
            "additionalProperties": True,
        },
        "proof": {"type": ["object", "null"]},
    },
    "additionalProperties": True,
}


class EvidenceSchemaError(ValueError):
    """Evidence JSON failed schema validation."""


def _type_name(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int) and not isinstance(value, bool):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, dict):
        return "object"
    if isinstance(value, list):
        return "array"
    return type(value).__name__


def _matches_type(value: Any, expected: str) -> bool:
    if expected == "null":
        return value is None
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return (isinstance(value, (int, float)) and not isinstance(value, bool))
    if expected == "string":
        return isinstance(value, str)
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    return False


def _validate_node(node: Any, schema: dict[str, Any], path: str) -> list[str]:
    errors: list[str] = []
    type_spec = schema.get("type")
    if type_spec is not None:
        allowed = type_spec if isinstance(type_spec, list) else [type_spec]
        if not any(_matches_type(node, t) for t in allowed):
            errors.append(
                f"{path}: expected type {allowed}, got {_type_name(node)}"
            )
            return errors

    if "minLength" in schema and isinstance(node, str):
        if len(node) < int(schema["minLength"]):
            errors.append(f"{path}: string shorter than minLength")

    if isinstance(node, dict):
        for key in schema.get("required", []):
            if key not in node:
                errors.append(f"{path}.{key}: required field missing")
        props = schema.get("properties") or {}
        for key, value in node.items():
            if key in props:
                errors.extend(_validate_node(value, props[key], f"{path}.{key}"))
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}.{key}: additional property not allowed")
    return errors


def validate_evidence(ev: Any, schema: Optional[dict[str, Any]] = None) -> None:
    """Validate evidence against EVIDENCE_SCHEMA. Raises EvidenceSchemaError."""
    sch = schema or EVIDENCE_SCHEMA
    if not isinstance(ev, dict):
        raise EvidenceSchemaError("evidence root must be an object")
    errors = _validate_node(ev, sch, "$")
    if errors:
        raise EvidenceSchemaError("; ".join(errors))


def parse_rfc3339(value: str) -> datetime:
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    return datetime.fromisoformat(raw).astimezone(timezone.utc)


def evidence_age_hours(ev: dict[str, Any], now: Optional[datetime] = None) -> float:
    """Compute evidence age solely from collected_at.

    Missing, unparseable, or future timestamps are treated as infinitely stale
    (fail closed). metrics.evidence_age_hours is never trusted.
    """
    collected = ev.get("collected_at")
    if not collected or not isinstance(collected, str):
        return float("inf")
    try:
        when = parse_rfc3339(collected)
    except (TypeError, ValueError):
        return float("inf")
    ref = now or datetime.now(timezone.utc)
    delta = (ref - when).total_seconds()
    if delta < 0:
        # Future timestamp — clock skew or tampering; fail closed.
        return float("inf")
    return delta / 3600.0


def check_bool(checks: dict[str, Any], key: str) -> bool:
    """Fail closed: only a literal JSON/Python True counts as pass."""
    return checks.get(key) is True


def evaluate(
    ev: dict[str, Any],
    contract: dict[str, Any],
    *,
    now: Optional[datetime] = None,
    validate: bool = True,
) -> dict[str, Any]:
    if validate:
        validate_evidence(ev)

    checks = ev.get("checks") or {}
    metrics = ev.get("metrics") or {}

    backup_ok = check_bool(checks, "backup")
    artifact_ok = check_bool(checks, "artifact_integrity")
    restore_ok = check_bool(checks, "restore_completed")
    app_ok = check_bool(checks, "application_health")
    data_ok = check_bool(checks, "data_verification")

    rto = metrics.get("rto_seconds")
    rto_max = int(contract["rto_seconds_max"])
    rto_ok = (
        restore_ok
        and rto is not None
        and isinstance(rto, int)
        and not isinstance(rto, bool)
        and int(rto) <= rto_max
    )

    age_h = evidence_age_hours(ev, now=now)
    age_max = int(contract["evidence_freshness_hours_max"])
    fresh_ok = age_h != float("inf") and float(age_h) <= age_max

    components = ev.get("components") or {}
    multi_service = components.get("postgres") is True and components.get("s3") is True
    consistency_required = (
        contract.get("cross_component_consistency") == "required" and multi_service
    ) or ("cross_component_consistency" in checks)
    consistency_ok = check_bool(checks, "cross_component_consistency")

    clauses = [
        ("backup", backup_ok, "required"),
        ("artifact_integrity", artifact_ok, "required"),
        ("isolated_restore", restore_ok, "required"),
        ("application_ready", app_ok, "required"),
        ("data_verification", data_ok, "required"),
    ]
    if consistency_required:
        clauses.append(
            ("cross_component_consistency", consistency_ok, "required")
        )
    clauses += [
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

    results = {
        "Backup": "PASS" if backup_ok else "FAIL",
        "Artifact integrity": "PASS" if artifact_ok else "FAIL",
        "Isolated restore": (
            "PASS"
            if restore_ok
            else (
                "BLOCKED"
                if blocked in ("validate", None) and not artifact_ok
                else "FAIL"
            )
        ),
        "Application ready": (
            "PASS" if app_ok else ("—" if not restore_ok else "FAIL")
        ),
        "Recovery marker": (
            "PASS" if data_ok else ("—" if not restore_ok else "FAIL")
        ),
    }
    if consistency_required:
        results["Cross-component consistency"] = (
            "PASS" if consistency_ok else ("—" if not restore_ok else "FAIL")
        )

    if blocked == "validate" or (not artifact_ok and not restore_ok):
        results["Isolated restore"] = "BLOCKED"
        results["Application ready"] = "—"
        results["Recovery marker"] = "—"
        if consistency_required:
            results["Cross-component consistency"] = "—"

    return {
        "verdict": verdict,
        "reason": reason,
        "blocked_at": blocked,
        "drill_id": drill_id,
        "scenario": scenario,
        "results": results,
        "clauses": [{"name": n, "ok": ok, "requirement": req} for n, ok, req in clauses],
        "metrics": {
            "rpo_seconds": metrics.get("rpo_seconds"),
            "rto_seconds": rto,
            "rto_max_seconds": rto_max,
            "evidence_age_hours": None if age_h == float("inf") else age_h,
            "evidence_freshness_hours_max": age_max,
            "backup_actionset": ev.get("backup_actionset"),
            "restore_actionset": ev.get("restore_actionset"),
            "drill_namespace": ev.get("drill_namespace"),
            "backup_location": ev.get("backup_location"),
            "marker_uuid": (ev.get("proof") or {}).get("marker_uuid"),
            "backup_sha256": (ev.get("proof") or {}).get("backup_sha256"),
        },
        "raw_clauses": clauses,
    }


def fmt_duration(seconds: Any) -> str:
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


def fmt_age_minutes(hours: Any) -> str:
    if hours is None:
        return "—"
    mins = int(float(hours) * 60)
    if mins <= 0:
        return "0m"
    if mins < 60:
        return f"{mins}m"
    h, m = divmod(mins, 60)
    return f"{h}h {m}m"


def render_report(
    ev: dict[str, Any],
    cfg: dict[str, Any],
    evaluation: dict[str, Any],
    evidence_path: str,
) -> dict[str, Any]:
    contract = cfg["contract"]
    return {
        "concept": "Recovery Contract",
        "tagline": cfg.get("tagline", "Restore should be proved, not assumed."),
        "lifecycle": cfg.get("lifecycle"),
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_evidence": evidence_path,
        "drill_id": evaluation["drill_id"],
        "scenario": evaluation["scenario"],
        "verdict": evaluation["verdict"],
        "reason": evaluation["reason"],
        "blocked_at": evaluation["blocked_at"],
        "contract": contract,
        "results": evaluation["results"],
        "metrics": evaluation["metrics"],
        "clauses": evaluation["clauses"],
        "proof": ev.get("proof"),
    }


def write_outputs(report: dict[str, Any], out_dir: Path, clauses: list) -> None:
    out_json = out_dir / "recovery-verdict.json"
    out_md = out_dir / "recovery-verdict.md"
    out_json.write_text(json.dumps(report, indent=2) + "\n")

    drill_id = report["drill_id"]
    verdict = report["verdict"]
    scenario = report["scenario"]
    reason = report["reason"]
    results = report["results"]
    metrics = report["metrics"]

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
        f"- RPO: {fmt_duration(metrics.get('rpo_seconds'))}",
        f"- RTO: {fmt_duration(metrics.get('rto_seconds'))}",
        f"- Evidence age: {fmt_age_minutes(metrics.get('evidence_age_hours'))}",
        "",
        "## Recovery Contract",
        "",
    ]
    for n, ok, req in clauses:
        lines.append(f"- {n}: {req} → {'PASS' if ok else 'FAIL'}")
    lines += ["", f"**RECOVERY {verdict}**", ""]
    out_md.write_text("\n".join(lines) + "\n")


def print_card(report: dict[str, Any], clauses: list) -> None:
    results = report["results"]
    metrics = report["metrics"]
    verdict = report["verdict"]
    reason = report["reason"]
    id4 = f"{int(report['drill_id']):04d}"
    w = 44
    print("┌" + "─" * w + "┐")
    print(f"│  RECOVERY DRILL #{id4:<32}│")
    print("├" + "─" * w + "┤")
    for label, val in results.items():
        print(f"│  {label:<22} {val:<19}│")
    print("├" + "─" * w + "┤")
    print(f"│  {'RPO':<22} {fmt_duration(metrics.get('rpo_seconds')):<19}│")
    print(f"│  {'RTO':<22} {fmt_duration(metrics.get('rto_seconds')):<19}│")
    print(
        f"│  {'Evidence age':<22} {fmt_age_minutes(metrics.get('evidence_age_hours')):<19}│"
    )
    print("├" + "─" * w + "┤")
    print(f"│  {'RECOVERY':<22} {verdict:<19}│")
    if reason:
        print(f"│  {'Reason':<22} {reason:<19}│")
    print("└" + "─" * w + "┘")


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(
            "Usage: evaluate_contract.py <evidence.json> <contract.json> <out_dir>",
            file=sys.stderr,
        )
        return 1

    evidence_path = Path(argv[1])
    cfg_path = Path(argv[2])
    out_dir = Path(argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)

    if not evidence_path.is_file():
        print(f"No evidence JSON found at {evidence_path}", file=sys.stderr)
        return 1

    try:
        ev = json.loads(evidence_path.read_text())
        cfg = json.loads(cfg_path.read_text())
        contract = cfg["contract"]
        validate_evidence(ev)
    except (json.JSONDecodeError, KeyError, TypeError, EvidenceSchemaError) as exc:
        print(f"invalid evidence/contract: {exc}", file=sys.stderr)
        return 1

    evaluation = evaluate(ev, contract, validate=False)
    report = render_report(ev, cfg, evaluation, str(evidence_path))
    write_outputs(report, out_dir, evaluation["raw_clauses"])
    print_card(report, evaluation["raw_clauses"])
    print(f"wrote {out_dir / 'recovery-verdict.json'}")
    print(f"wrote {out_dir / 'recovery-verdict.md'}")

    if evaluation["verdict"] == "PROVED":
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
