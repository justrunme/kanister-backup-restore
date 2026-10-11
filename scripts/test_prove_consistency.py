#!/usr/bin/env python3
"""Unit tests for cross-component consistency proof."""

from __future__ import annotations

import hashlib

from prove_consistency import prove


def _manifest(generation: int, objects: list[dict], skew_pg: str, skew_s3: str):
    return {
        "generation": generation,
        "pg_backup_timestamp": skew_pg,
        "s3_backup_timestamp": skew_s3,
        "objects": objects,
    }


def test_consistency_ok():
    body = b"hello-object"
    sha = hashlib.sha256(body).hexdigest()
    key = "app-data/obj-1.bin"
    result = prove(
        pg_rows=[{"object_key": key, "sha256": sha, "generation": 10}],
        pg_generation=10,
        restored_objects={key: body},
        rp_manifest=_manifest(
            10,
            [{"object_key": key, "sha256": sha}],
            "2026-10-11T12:00:00Z",
            "2026-10-11T12:00:05Z",
        ),
        skew_max_seconds=60,
    )
    assert result["ok"] is True
    assert result["skew_seconds"] == 5


def test_missing_object_fails():
    sha = hashlib.sha256(b"x").hexdigest()
    key = "app-data/missing.bin"
    result = prove(
        pg_rows=[{"object_key": key, "sha256": sha, "generation": 1}],
        pg_generation=1,
        restored_objects={},
        rp_manifest=_manifest(
            1,
            [{"object_key": key, "sha256": sha}],
            "2026-10-11T12:00:00Z",
            "2026-10-11T12:00:00Z",
        ),
        skew_max_seconds=60,
    )
    assert result["ok"] is False
    assert any("missing" in e for e in result["errors"])


def test_corrupt_object_fails():
    key = "app-data/obj.bin"
    expected = hashlib.sha256(b"good").hexdigest()
    result = prove(
        pg_rows=[{"object_key": key, "sha256": expected, "generation": 2}],
        pg_generation=2,
        restored_objects={key: b"bad"},
        rp_manifest=_manifest(
            2,
            [{"object_key": key, "sha256": expected}],
            "2026-10-11T12:00:00Z",
            "2026-10-11T12:00:00Z",
        ),
        skew_max_seconds=60,
    )
    assert result["ok"] is False
    assert any("sha256" in e for e in result["errors"])


def test_generation_mismatch_fails():
    body = b"payload"
    sha = hashlib.sha256(body).hexdigest()
    key = "app-data/g.bin"
    result = prove(
        pg_rows=[{"object_key": key, "sha256": sha, "generation": 1}],
        pg_generation=1,
        restored_objects={key: body},
        rp_manifest=_manifest(
            99,
            [{"object_key": key, "sha256": sha}],
            "2026-10-11T12:00:00Z",
            "2026-10-11T12:00:00Z",
        ),
        skew_max_seconds=60,
    )
    assert result["ok"] is False
    assert any("generation mismatch" in e for e in result["errors"])


def test_skew_breach_fails():
    body = b"payload"
    sha = hashlib.sha256(body).hexdigest()
    key = "app-data/g.bin"
    result = prove(
        pg_rows=[{"object_key": key, "sha256": sha, "generation": 3}],
        pg_generation=3,
        restored_objects={key: body},
        rp_manifest=_manifest(
            3,
            [{"object_key": key, "sha256": sha}],
            "2026-10-11T12:00:00Z",
            "2026-10-11T13:00:00Z",
        ),
        skew_max_seconds=60,
    )
    assert result["ok"] is False
    assert any("skew" in e for e in result["errors"])
