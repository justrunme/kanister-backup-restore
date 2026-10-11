#!/usr/bin/env python3
"""Pytest coverage for Recovery Contract evaluation."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from evaluate_contract import evaluate, evidence_age_hours


CONTRACT = {
    "artifact_integrity": "required",
    "isolated_restore": "required",
    "application_ready": "required",
    "data_verification": "required",
    "rto_seconds_max": 60,
    "evidence_freshness_hours_max": 24,
}


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
            "rpo_seconds": 12,
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


def test_missing_check_fails_closed():
    ev = _base_evidence()
    del ev["checks"]["backup"]
    result = evaluate(ev, CONTRACT, now=datetime(2026, 10, 11, 12, 0, tzinfo=timezone.utc))
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "backup"


def test_stale_evidence_unproved():
    now = datetime(2026, 10, 12, 14, 0, tzinfo=timezone.utc)  # 26h later
    result = evaluate(_base_evidence(), CONTRACT, now=now)
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "evidence_freshness"
    assert result["metrics"]["evidence_age_hours"] == 26.0


def test_rto_breach():
    ev = _base_evidence()
    ev["metrics"]["rto_seconds"] = 90
    result = evaluate(ev, CONTRACT, now=datetime(2026, 10, 11, 12, 0, tzinfo=timezone.utc))
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "rto"


def test_data_verification_failure():
    ev = _base_evidence(scenario="noop-restore", blocked_at="verify")
    ev["checks"]["data_verification"] = False
    result = evaluate(ev, CONTRACT, now=datetime(2026, 10, 11, 12, 0, tzinfo=timezone.utc))
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
    result = evaluate(ev, contract, now=datetime(2026, 10, 11, 12, 0, tzinfo=timezone.utc))
    assert result["verdict"] == "UNPROVED"
    assert result["reason"] == "rto"
    assert result["metrics"]["rto_max_seconds"] == 20
