#!/usr/bin/env python3
"""Pytest coverage for Recovery Contract evaluation."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from evaluate_contract import (
    EvidenceSchemaError,
    check_bool,
    evaluate,
    evidence_age_hours,
    main,
    validate_evidence,
)


CONTRACT = {
    "artifact_integrity": "required",
    "isolated_restore": "required",
    "application_ready": "required",
    "data_verification": "required",
    "rto_seconds_max": 60,
    "evidence_freshness_hours_max": 24,
}

NOW = datetime(2026, 10, 11, 12, 0, tzinfo=timezone.utc)


def _base_evidence(**overrides):
    ev = {
        "drill_id": 1,
        "scenario": "happy-path",
        "blocked_at": None,
        "collected_at": "2026-10-11T12:00:00Z",
        "checks": {
            "backup": True,
            "artifact_integrity": True,
            "restore_completed": True,
            "application_health": True,
            "data_verification": True,
            "rto_within_target": True,
            "evidence_fresh": True,
        },
        "metrics": {
            "component_skew_seconds": 12,
            "rto_seconds": 30,
            "drill_id": 1,
        },
    }
    ev.update(overrides)
    return ev


def test_happy_path_proved():
    now = datetime(2026, 10, 11, 12, 30, tzinfo=timezone.utc)
    result = evaluate(_base_evidence(), CONTRACT, now=now)
    assert result["verdict"] == "PROVED"
    assert result["reason"] is None


def test_missing_backup_fails_closed():
    ev = _base_evidence()
    del ev["checks"]["backup"]
    with pytest.raises(EvidenceSchemaError):
        evaluate(ev, CONTRACT, now=NOW)
    # Even without schema gate, check_bool fails closed.
    result = evaluate(ev, CONTRACT, now=NOW, validate=False)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "backup"


def test_backup_string_false_fails_closed():
    ev = _base_evidence()
    ev["checks"]["backup"] = "false"
    with pytest.raises(EvidenceSchemaError):
        validate_evidence(ev)
    assert check_bool(ev["checks"], "backup") is False
    result = evaluate(ev, CONTRACT, now=NOW, validate=False)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "backup"


def test_backup_integer_one_fails_closed():
    ev = _base_evidence()
    ev["checks"]["backup"] = 1
    assert check_bool(ev["checks"], "backup") is False
    result = evaluate(ev, CONTRACT, now=NOW, validate=False)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "backup"


def test_stale_evidence_unproved():
    now = datetime(2026, 10, 12, 14, 0, tzinfo=timezone.utc)  # 26h later
    result = evaluate(_base_evidence(), CONTRACT, now=now)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "evidence_freshness"
    assert result["metrics"]["evidence_age_hours"] == 26.0


def test_missing_collected_at_unproved():
    ev = _base_evidence()
    del ev["collected_at"]
    with pytest.raises(EvidenceSchemaError):
        validate_evidence(ev)
    age = evidence_age_hours(ev, now=NOW)
    assert age == float("inf")
    result = evaluate(ev, CONTRACT, now=NOW, validate=False)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "evidence_freshness"


def test_metrics_evidence_age_ignored_when_collected_at_stale():
    """supplied evidence_age_hours=0 must not override an old collected_at."""
    now = datetime(2026, 10, 12, 14, 0, tzinfo=timezone.utc)  # 26h after collected_at
    ev = _base_evidence()
    ev["metrics"]["evidence_age_hours"] = 0
    age = evidence_age_hours(ev, now=now)
    assert age == 26.0
    result = evaluate(ev, CONTRACT, now=now)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "evidence_freshness"
    assert result["metrics"]["evidence_age_hours"] == 26.0


def test_future_timestamp_unproved():
    ev = _base_evidence(collected_at="2026-10-11T18:00:00Z")  # 6h in the future vs NOW
    age = evidence_age_hours(ev, now=NOW)
    assert age == float("inf")
    result = evaluate(ev, CONTRACT, now=NOW)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "evidence_freshness"
    assert result["metrics"]["evidence_age_hours"] is None


def test_unparseable_collected_at_unproved():
    ev = _base_evidence(collected_at="not-a-timestamp")
    age = evidence_age_hours(ev, now=NOW)
    assert age == float("inf")
    result = evaluate(ev, CONTRACT, now=NOW, validate=False)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "evidence_freshness"


def test_rto_breach():
    ev = _base_evidence()
    ev["metrics"]["rto_seconds"] = 90
    result = evaluate(ev, CONTRACT, now=NOW)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "rto"


def test_data_verification_failure():
    ev = _base_evidence(scenario="noop-restore", blocked_at="verify")
    ev["checks"]["data_verification"] = False
    result = evaluate(ev, CONTRACT, now=NOW)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "data_verification"


def test_evidence_age_from_collected_at():
    collected = datetime(2026, 10, 11, 10, 0, tzinfo=timezone.utc)
    now = collected + timedelta(hours=2, minutes=30)
    age = evidence_age_hours({"collected_at": "2026-10-11T10:00:00Z"}, now=now)
    assert abs(age - 2.5) < 1e-9


def test_configurable_rto_target():
    contract = dict(CONTRACT)
    contract["rto_seconds_max"] = 20
    ev = _base_evidence()
    ev["metrics"]["rto_seconds"] = 25
    result = evaluate(ev, contract, now=NOW)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "rto"
    assert result["metrics"]["rto_max_seconds"] == 20


def test_schema_rejects_non_boolean_check():
    ev = _base_evidence()
    ev["checks"]["artifact_integrity"] = "true"
    with pytest.raises(EvidenceSchemaError):
        validate_evidence(ev)


def test_main_non_proved_exit_nonzero(tmp_path: Path):
    cfg = tmp_path / "contract.json"
    cfg.write_text(
        json.dumps(
            {
                "tagline": "Restore should be proved, not assumed.",
                "lifecycle": "PROTECT → VALIDATE → RESTORE → PROVE",
                "contract": CONTRACT,
            }
        )
        + "\n"
    )
    ev_path = tmp_path / "drill.json"
    ev = _base_evidence()
    ev["checks"]["backup"] = False
    ev_path.write_text(json.dumps(ev) + "\n")
    out = tmp_path / "out"
    rc = main(["evaluate_contract.py", str(ev_path), str(cfg), str(out)])
    assert rc != 0
    assert rc == 2


def test_main_invalid_schema_exit_nonzero(tmp_path: Path):
    cfg = tmp_path / "contract.json"
    cfg.write_text(json.dumps({"contract": CONTRACT}) + "\n")
    ev_path = tmp_path / "drill.json"
    ev_path.write_text(json.dumps({"drill_id": 1}) + "\n")
    out = tmp_path / "out"
    rc = main(["evaluate_contract.py", str(ev_path), str(cfg), str(out)])
    assert rc != 0
    assert rc == 1
