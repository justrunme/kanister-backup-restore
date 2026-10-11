#!/usr/bin/env python3
"""Minimal SigV4 S3 client for the in-cluster SeaweedFS/MinIO endpoint via port-forward.

Usage:
  s3-client.py put <key> <file>
  s3-client.py get <key> <file>
  s3-client.py head <key>
  s3-client.py delete <key>
  s3-client.py copy <src-key> <dst-key>
"""

from __future__ import annotations

import hashlib
import hmac
import datetime
import os
import sys
import urllib.error
import urllib.request


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def request(
    method: str,
    key: str = "",
    body: bytes = b"",
    *,
    port: int,
    bucket: str,
    access: str,
    secret: str,
    region: str,
) -> tuple[int, bytes]:
    host = f"127.0.0.1:{port}"
    if key:
        if not key.startswith("/"):
            key = "/" + key
        uri = f"/{bucket}{key}"
    else:
        uri = f"/{bucket}"

    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()
    canonical_headers = (
        f"host:{host}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amzdate}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = "\n".join(
        [method, uri, "", canonical_headers, signed_headers, payload_hash]
    )
    scope = f"{datestamp}/{region}/s3/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amzdate,
            scope,
            hashlib.sha256(canonical_request.encode()).hexdigest(),
        ]
    )
    k = _sign(("AWS4" + secret).encode(), datestamp)
    k = _sign(k, region)
    k = _sign(k, "s3")
    k = _sign(k, "aws4_request")
    signature = hmac.new(k, string_to_sign.encode(), hashlib.sha256).hexdigest()
    auth = (
        f"AWS4-HMAC-SHA256 Credential={access}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    req = urllib.request.Request(
        f"http://{host}{uri}",
        data=body if method in ("PUT", "POST") else None,
        method=method,
        headers={
            "Host": host,
            "x-amz-date": amzdate,
            "x-amz-content-sha256": payload_hash,
            "Authorization": auth,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read()
        return e.code, detail


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    action = argv[1]
    port = int(os.environ.get("S3_LOCAL_PORT", "18333"))
    bucket = os.environ.get("S3_BUCKET", "kanister-drills")
    access = os.environ.get("S3_ACCESS_KEY", "admin")
    secret = os.environ.get("S3_SECRET_KEY", "admin12345")
    region = os.environ.get("S3_REGION", "us-east-1")

    if action == "put":
        key, path = argv[2], argv[3]
        body = open(path, "rb").read()
        code, _ = request(
            "PUT", key, body, port=port, bucket=bucket, access=access, secret=secret, region=region
        )
        print(f"PUT /{bucket}/{key} -> {code} sha256={hashlib.sha256(body).hexdigest()}")
        return 0 if code in (200, 201) else 1

    if action == "get":
        key, path = argv[2], argv[3]
        code, body = request(
            "GET", key, port=port, bucket=bucket, access=access, secret=secret, region=region
        )
        if code != 200:
            print(f"GET /{bucket}/{key} -> {code}", file=sys.stderr)
            return 1
        open(path, "wb").write(body)
        print(f"GET /{bucket}/{key} -> {code} bytes={len(body)}")
        return 0

    if action == "head":
        key = argv[2]
        code, _ = request(
            "HEAD", key, port=port, bucket=bucket, access=access, secret=secret, region=region
        )
        print(f"HEAD /{bucket}/{key} -> {code}")
        return 0 if code == 200 else 1

    if action == "delete":
        key = argv[2]
        code, _ = request(
            "DELETE", key, port=port, bucket=bucket, access=access, secret=secret, region=region
        )
        print(f"DELETE /{bucket}/{key} -> {code}")
        return 0 if code in (200, 204) else 1

    if action == "copy":
        src, dst = argv[2], argv[3]
        code, body = request(
            "GET", src, port=port, bucket=bucket, access=access, secret=secret, region=region
        )
        if code != 200:
            print(f"copy GET {src} -> {code}", file=sys.stderr)
            return 1
        code2, _ = request(
            "PUT", dst, body, port=port, bucket=bucket, access=access, secret=secret, region=region
        )
        print(f"COPY {src} -> {dst} ({code2}) sha256={hashlib.sha256(body).hexdigest()}")
        return 0 if code2 in (200, 201) else 1

    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
