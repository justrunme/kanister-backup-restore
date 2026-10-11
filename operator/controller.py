#!/usr/bin/env python3
"""Lightweight Recovery Contract operator (kopf).

Reconciles RecoveryDrill CRs by launching an async Job that runs
app-recovery-drill.sh (never synchronously inside the timer). Updates status
(verdict, last success, evidence digest) and exports Prometheus metrics.

Stuck phase==Running after a crash/timeout is cleared so reconciliation resumes.
"""

from __future__ import annotations

import hashlib
import json
import os
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
SKEW = Gauge(
    "recovery_component_skew_seconds",
    "Measured component skew between Postgres and S3 recovery points",
    ["scenario", "drill", "namespace"],
)

API_GROUP = "recovery.justrunme.com"
API_VERSION = "v1alpha1"
ROOT = Path(os.environ.get("RECOVERY_ROOT", "/workspace"))
RUNNING_STUCK_SECONDS = int(os.environ.get("DRILL_RUNNING_STUCK_SECONDS", "900"))


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_ts(value: str) -> Optional[datetime]:
    if not value:
        return None
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(raw).astimezone(timezone.utc)
    except ValueError:
        return None


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


def _job_name(namespace: str, name: str) -> str:
    base = f"drill-{namespace}-{name}"
    return base[:63].rstrip("-")


def _ensure_drill_job(namespace: str, name: str, scenario: str, evidence_dir: str) -> str:
    """Create a Job that runs the drill asynchronously. Returns job name."""
    batch = client.BatchV1Api()
    job_name = _job_name(namespace, name)
    try:
        batch.read_namespaced_job(job_name, namespace)
        return job_name
    except client.exceptions.ApiException as exc:
        if exc.status != 404:
            raise

    root = str(ROOT)
    container = client.V1Container(
        name="drill",
        image=os.environ.get("DRILL_IMAGE", "python:3.12-slim"),
        command=["bash", "-lc"],
        args=[
            "set -euo pipefail; "
            f"cd {root}; "
            "pip install -q -r operator/requirements.txt >/dev/null; "
            f"export EVIDENCE_DIR={evidence_dir}; "
            f"if [ '{scenario}' != 'happy-path' ]; then scripts/break.sh {scenario}; fi; "
            "bash scripts/app-recovery-drill.sh"
        ],
        env=[
            client.V1EnvVar(name="RECOVERY_ROOT", value=root),
            client.V1EnvVar(name="EVIDENCE_DIR", value=evidence_dir),
        ],
        volume_mounts=[
            client.V1VolumeMount(name="workspace", mount_path=root),
        ],
    )
    # Prefer hostPath only when explicitly configured for kind CI; otherwise emptyDir
    # and rely on the image having the scripts baked in.
    host_path = os.environ.get("RECOVERY_HOST_PATH", "")
    if host_path:
        volumes = [
            client.V1Volume(
                name="workspace",
                host_path=client.V1HostPathVolumeSource(path=host_path, type="Directory"),
            )
        ]
    else:
        # In-process fallback path: run locally without a Job when DRILL_INLINE=1
        volumes = [client.V1Volume(name="workspace", empty_dir=client.V1EmptyDirVolumeSource())]

    job = client.V1Job(
        metadata=client.V1ObjectMeta(
            name=job_name,
            namespace=namespace,
            labels={
                "app.kubernetes.io/name": "kanister-backup-restore",
                "recovery.justrunme.com/drill": name,
            },
        ),
        spec=client.V1JobSpec(
            backoff_limit=0,
            ttl_seconds_after_finished=600,
            template=client.V1PodTemplateSpec(
                metadata=client.V1ObjectMeta(labels={"recovery.justrunme.com/drill": name}),
                spec=client.V1PodSpec(
                    restart_policy="Never",
                    service_account_name="recovery-contract-operator",
                    containers=[container],
                    volumes=volumes,
                ),
            ),
        ),
    )
    batch.create_namespaced_job(namespace, job)
    return job_name


def _job_finished(namespace: str, job_name: str) -> Optional[str]:
    """Return 'Succeeded', 'Failed', or None if still running / missing."""
    batch = client.BatchV1Api()
    try:
        job = batch.read_namespaced_job(job_name, namespace)
    except client.exceptions.ApiException as exc:
        if exc.status == 404:
            return None
        raise
    status = job.status
    if status is None:
        return None
    if status.succeeded and status.succeeded > 0:
        return "Succeeded"
    if status.failed and status.failed > 0:
        return "Failed"
    return None


def _run_inline(scenario: str, evidence_dir: Path) -> int:
    """Kind CI helper: run the drill in-process (still not inside the kopf event thread
    when launched via subprocess from a short-lived helper). Used when DRILL_INLINE=1."""
    import subprocess

    env = os.environ.copy()
    env["EVIDENCE_DIR"] = str(evidence_dir)
    evidence_dir.mkdir(parents=True, exist_ok=True)
    if scenario != "happy-path":
        subprocess.run(
            [str(ROOT / "scripts/break.sh"), scenario],
            check=True,
            env=env,
            cwd=str(ROOT),
        )
    proc = subprocess.run(
        ["bash", str(ROOT / "scripts/app-recovery-drill.sh")],
        env=env,
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    (evidence_dir / "operator-drill.stdout").write_text(proc.stdout or "")
    (evidence_dir / "operator-drill.stderr").write_text(proc.stderr or "")
    return proc.returncode


@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, **_: Any) -> None:
    settings.persistence.progress_storage = kopf.AnnotationsProgressStorage()
    port = int(os.environ.get("METRICS_PORT", "8080"))
    start_http_server(port)
    if os.environ.get("KUBERNETES_SERVICE_HOST"):
        kubernetes.config.load_incluster_config()
    else:
        kubernetes.config.load_kube_config()


@kopf.timer(
    API_GROUP,
    API_VERSION,
    "recoverydrills",
    interval=float(os.environ.get("DRILL_POLL_SECONDS", "60")),
    idle=10,
)
def reconcile_drill(
    spec: dict[str, Any],
    status: Optional[dict[str, Any]],
    name: str,
    namespace: str,
    **_: Any,
) -> None:
    if spec.get("suspend"):
        return
    status = status or {}
    scenario = spec.get("scenario") or "happy-path"
    evidence_dir = ROOT / ".evidence" / f"crd-{namespace}-{name}"
    evidence_dir.mkdir(parents=True, exist_ok=True)

    phase = status.get("phase")
    if phase == "Running":
        started = _parse_ts(status.get("lastRunTime") or "")
        stuck = False
        if started is None:
            stuck = True
        else:
            age = (datetime.now(timezone.utc) - started).total_seconds()
            stuck = age > RUNNING_STUCK_SECONDS
        job_name = status.get("jobName") or _job_name(namespace, name)
        finished = None
        if os.environ.get("DRILL_INLINE") != "1":
            finished = _job_finished(namespace, job_name)
        if finished is None and not stuck and os.environ.get("DRILL_INLINE") != "1":
            return
        if stuck and finished is None and os.environ.get("DRILL_INLINE") != "1":
            _patch_status(
                namespace,
                name,
                {
                    "phase": "Failed",
                    "lastVerdict": "UNPROVED",
                    "lastReason": "stuck_running",
                    "lastRunTime": _now(),
                    "message": f"cleared stuck Running after {RUNNING_STUCK_SECONDS}s",
                    "jobName": job_name,
                },
            )
            return
        # Fall through to collect results when finished or inline.

    # Launch or continue
    if phase not in ("Running",) or not status.get("jobName"):
        if phase in ("Succeeded", "Failed") and not spec.get("runOnceAgain"):
            # Idle until a new schedule trigger; timer keeps watching.
            interval = float(spec.get("intervalSeconds") or 0)
            last = _parse_ts(status.get("lastRunTime") or "")
            if interval <= 0 or last is None:
                return
            age = (datetime.now(timezone.utc) - last).total_seconds()
            if age < interval:
                return

        _patch_status(
            namespace,
            name,
            {
                "phase": "Running",
                "lastRunTime": _now(),
                "message": f"starting scenario={scenario}",
                "jobName": _job_name(namespace, name),
            },
        )

        if os.environ.get("DRILL_INLINE") == "1":
            # Async relative to kopf: spawn background process so the timer returns.
            import subprocess
            import threading

            def _bg() -> None:
                rc = _run_inline(scenario, evidence_dir)
                (evidence_dir / "operator-drill.rc").write_text(str(rc))

            threading.Thread(target=_bg, daemon=True).start()
            return

        job_name = _ensure_drill_job(namespace, name, scenario, str(evidence_dir))
        _patch_status(
            namespace,
            name,
            {
                "phase": "Running",
                "lastRunTime": _now(),
                "message": f"job={job_name} scenario={scenario}",
                "jobName": job_name,
            },
        )
        return

    # Collect results
    if os.environ.get("DRILL_INLINE") == "1":
        rc_path = evidence_dir / "operator-drill.rc"
        if not rc_path.is_file():
            # Still running in background thread.
            started = _parse_ts(status.get("lastRunTime") or "")
            if started and (datetime.now(timezone.utc) - started).total_seconds() > RUNNING_STUCK_SECONDS:
                _patch_status(
                    namespace,
                    name,
                    {
                        "phase": "Failed",
                        "lastVerdict": "UNPROVED",
                        "lastReason": "stuck_running",
                        "lastRunTime": _now(),
                        "message": "inline drill stuck",
                    },
                )
            return
        proc_rc = int(rc_path.read_text().strip() or "1")
    else:
        job_name = status.get("jobName") or _job_name(namespace, name)
        finished = _job_finished(namespace, job_name)
        if finished is None:
            return
        proc_rc = 0 if finished == "Succeeded" else 1

    verdict_path = evidence_dir / "recovery-verdict.json"
    evidence_path = evidence_dir / "drill-latest.json"
    verdict = "UNPROVED"
    reason = ""
    rto = None
    skew = None
    if verdict_path.is_file():
        report = json.loads(verdict_path.read_text())
        verdict = report.get("verdict") or "UNPROVED"
        reason = report.get("reason") or ""
        metrics = report.get("metrics") or {}
        rto = metrics.get("rto_seconds")
        skew = metrics.get("component_skew_seconds")

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
    if skew is not None:
        SKEW.labels(scenario=scenario, drill=name, namespace=namespace).set(float(skew))

    _patch_status(
        namespace,
        name,
        {
            "phase": "Succeeded" if proc_rc == 0 and verdict == "PROVED" else "Failed",
            "lastVerdict": verdict,
            "lastReason": reason,
            "lastSuccessTime": success_time,
            "lastRunTime": _now(),
            "evidenceDigest": digest,
            "rtoSeconds": rto,
            "componentSkewSeconds": skew,
            "jobName": status.get("jobName"),
            "message": f"verdict={verdict} reason={reason}",
        },
    )


@kopf.on.create(API_GROUP, API_VERSION, "recoverycontracts")
@kopf.on.update(API_GROUP, API_VERSION, "recoverycontracts")
def on_contract(spec: dict[str, Any], name: str, namespace: str, **_: Any) -> dict[str, Any]:
    targets = spec.get("targets") or []
    comps = sorted({t.get("component") for t in targets if t.get("component")})
    return {"message": f"contract active targets={','.join(comps)}"}
