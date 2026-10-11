#!/usr/bin/env python3
"""Lightweight Recovery Contract operator (kopf).

Reconciles RecoveryDrill CRs: runs app-recovery-drill.sh in-cluster via a Job
in an isolated namespace bounded by ResourceQuota/LimitRange, then updates
status (verdict, last success, evidence digest) and exports Prometheus metrics.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import kopf
import kubernetes
from kubernetes import client
from prometheus_client import Gauge, start_http_server

VERDICT = Gauge(
    "recovery_contract_verdict",
    "Recovery Contract verdict (1=PROVED, 0=UNPROVED)",
    ["scenario", "drill", "namespace"],
)
LAST_SUCCESS = Gauge(
    "recovery_last_success_timestamp",
    "Unix timestamp of last PROVED drill",
    ["drill", "namespace"],
)
RTO = Gauge(
    "recovery_rto_seconds",
    "Measured RTO for the latest drill",
    ["scenario", "drill", "namespace"],
)

API_GROUP = "recovery.justrunme.com"
API_VERSION = "v1alpha1"
ROOT = Path(os.environ.get("RECOVERY_ROOT", "/workspace"))


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _digest(path: Path) -> str:
    if not path.is_file():
        return ""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _patch_status(namespace: str, name: str, status: dict[str, Any]) -> None:
    api = client.CustomObjectsApi()
    api.patch_namespaced_custom_object_status(
        group=API_GROUP,
        version=API_VERSION,
        namespace=namespace,
        plural="recoverydrills",
        name=name,
        body={"status": status},
    )


@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, **_: Any) -> None:
    settings.persistence.progress_storage = kopf.AnnotationsProgressStorage()
    port = int(os.environ.get("METRICS_PORT", "8080"))
    start_http_server(port)
    kubernetes.config.load_incluster_config() if os.environ.get("KUBERNETES_SERVICE_HOST") else kubernetes.config.load_kube_config()


@kopf.timer(
    API_GROUP,
    API_VERSION,
    "recoverydrills",
    interval=float(os.environ.get("DRILL_POLL_SECONDS", "60")),
    idle=10,
)
def reconcile_drill(spec: dict[str, Any], status: Optional[dict[str, Any]], name: str, namespace: str, **_: Any) -> None:
    if spec.get("suspend"):
        return
    status = status or {}
    if status.get("phase") == "Running":
        return

    scenario = spec.get("scenario") or "happy-path"
    _patch_status(
        namespace,
        name,
        {
            "phase": "Running",
            "lastRunTime": _now(),
            "message": f"starting scenario={scenario}",
            "observedGeneration": 0,
        },
    )

    env = os.environ.copy()
    env["EVIDENCE_DIR"] = str(ROOT / ".evidence" / f"crd-{namespace}-{name}")
    Path(env["EVIDENCE_DIR"]).mkdir(parents=True, exist_ok=True)

    if scenario != "happy-path":
        subprocess.run(
            [str(ROOT / "scripts/break.sh"), scenario],
            check=False,
            env=env,
            cwd=str(ROOT),
        )

    script = ROOT / "scripts/app-recovery-drill.sh"
    proc = subprocess.run(
        ["bash", str(script)],
        env=env,
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )

    verdict_path = Path(env["EVIDENCE_DIR"]) / "recovery-verdict.json"
    evidence_path = Path(env["EVIDENCE_DIR"]) / "drill-latest.json"
    verdict = "UNPROVED"
    reason = ""
    rto = None
    if verdict_path.is_file():
        report = json.loads(verdict_path.read_text())
        verdict = report.get("verdict") or "UNPROVED"
        reason = report.get("reason") or ""
        rto = (report.get("metrics") or {}).get("rto_seconds")

    digest = _digest(evidence_path)
    success_time = status.get("lastSuccessTime")
    if verdict == "PROVED":
        success_time = _now()
        LAST_SUCCESS.labels(drill=name, namespace=namespace).set(time.time())

    VERDICT.labels(scenario=scenario, drill=name, namespace=namespace).set(
        1 if verdict == "PROVED" else 0
    )
    if rto is not None:
        RTO.labels(scenario=scenario, drill=name, namespace=namespace).set(float(rto))

    _patch_status(
        namespace,
        name,
        {
            "phase": "Succeeded" if proc.returncode == 0 else "Failed",
            "lastVerdict": verdict,
            "lastReason": reason,
            "lastSuccessTime": success_time,
            "lastRunTime": _now(),
            "evidenceDigest": digest,
            "rtoSeconds": rto,
            "message": (proc.stdout or "")[-500:] or (proc.stderr or "")[-500:],
        },
    )


@kopf.on.create(API_GROUP, API_VERSION, "recoverycontracts")
@kopf.on.update(API_GROUP, API_VERSION, "recoverycontracts")
def on_contract(spec: dict[str, Any], name: str, namespace: str, **_: Any) -> dict[str, Any]:
    targets = spec.get("targets") or []
    comps = sorted({t.get("component") for t in targets if t.get("component")})
    return {"message": f"contract active targets={','.join(comps)}"}
