#!/usr/bin/env python3
"""Prove cross-component consistency for a multi-service recovery point.

Checks:
  - every referenced S3 object exists with matching sha256
  - no missing required objects from the RP manifest
  - manifest generation equal across Postgres app_manifest / app_objects / RP
  - single logical recovery point (pg_ts / s3_ts skew within bound)

Exit 0 on success; prints JSON summary to stdout.
"""

from __future__ import annotations

import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def parse_ts(value: str) -> datetime:
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    return datetime.fromisoformat(raw).astimezone(timezone.utc)


def prove(
    *,
    pg_rows: list[dict[str, Any]],
    pg_generation: int,
    restored_objects: dict[str, bytes],
    rp_manifest: dict[str, Any],
    skew_max_seconds: int,
) -> dict[str, Any]:
    errors: list[str] = []
    rp_gen = int(rp_manifest.get("generation", -1))
    if pg_generation != rp_gen:
        errors.append(f"generation mismatch postgres={pg_generation} rp={rp_gen}")

    row_gens = {int(r["generation"]) for r in pg_rows}
    if row_gens and row_gens != {pg_generation}:
        errors.append(f"app_objects generation drift: {sorted(row_gens)}")

    required = {o["object_key"]: o["sha256"] for o in rp_manifest.get("objects", [])}
    for key, expected_sha in required.items():
        body = restored_objects.get(key)
        if body is None:
            errors.append(f"missing required object {key}")
            continue
        actual = hashlib.sha256(body).hexdigest()
        if actual != expected_sha:
            errors.append(f"sha256 mismatch for {key}: actual={actual} expected={expected_sha}")

    for row in pg_rows:
        key = row["object_key"]
        expected_sha = row["sha256"]
        body = restored_objects.get(key)
        if body is None:
            errors.append(f"postgres references missing object {key}")
            continue
        actual = hashlib.sha256(body).hexdigest()
        if actual != expected_sha:
            errors.append(
                f"postgres/S3 sha256 mismatch for {key}: pg={expected_sha} s3={actual}"
            )

    # Orphans among required set: objects restored that are not in PG or RP
    # (we only require that every referenced/required object is present; extras OK)
    pg_keys = {r["object_key"] for r in pg_rows}
    missing_in_pg = set(required) - pg_keys
    if missing_in_pg:
        errors.append(f"RP objects absent from postgres: {sorted(missing_in_pg)}")

    pg_ts = rp_manifest.get("pg_backup_timestamp")
    s3_ts = rp_manifest.get("s3_backup_timestamp")
    skew = None
    if pg_ts and s3_ts:
        try:
            skew = abs(int((parse_ts(pg_ts) - parse_ts(s3_ts)).total_seconds()))
            if skew > int(skew_max_seconds):
                errors.append(
                    f"recovery point skew {skew}s exceeds max {skew_max_seconds}s"
                )
        except ValueError as exc:
            errors.append(f"unparseable RP timestamps: {exc}")
    else:
        errors.append("missing pg_backup_timestamp or s3_backup_timestamp on RP")

    ok = len(errors) == 0
    return {
        "ok": ok,
        "errors": errors,
        "generation": pg_generation,
        "object_count": len(pg_rows),
        "required_count": len(required),
        "skew_seconds": skew,
        "skew_max_seconds": skew_max_seconds,
    }


def main(argv: list[str]) -> int:
    if len(argv) < 5:
        print(
            "Usage: prove_consistency.py <pg-rows.json> <pg-generation> "
            "<objects-dir> <rp-manifest.json> [skew_max]",
            file=sys.stderr,
        )
        return 2
    rows = json.loads(Path(argv[1]).read_text())
    generation = int(argv[2])
    objects_dir = Path(argv[3])
    manifest = json.loads(Path(argv[4]).read_text())
    skew_max = int(argv[5]) if len(argv) > 5 else 60

    restored: dict[str, bytes] = {}
    for meta in manifest.get("objects", []):
        key = meta["object_key"]
        # Objects are stored under objects_dir using flat sha-named files or key path
        candidate = objects_dir / meta.get("backup_name", Path(key).name)
        if candidate.is_file():
            restored[key] = candidate.read_bytes()
        else:
            # try nested path
            nested = objects_dir / key
            if nested.is_file():
                restored[key] = nested.read_bytes()

    result = prove(
        pg_rows=rows,
        pg_generation=generation,
        restored_objects=restored,
        rp_manifest=manifest,
        skew_max_seconds=skew_max,
    )
    print(json.dumps(result, indent=2))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
