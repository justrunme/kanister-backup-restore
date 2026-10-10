#!/usr/bin/env bash
# Diagnostics for a hung or failed kind drill. Never fails the caller.
set -u
NS="${KANISTER_NAMESPACE:-kanister}"

echo "=== pods -A -o wide ==="
kubectl get pods -A -o wide || true

echo "=== jobs -A -o wide ==="
kubectl get jobs -A -o wide || true

echo "=== describe failed/pending pods ==="
kubectl get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Succeeded" && $4 != "Completed" {print $1, $2}' | while read -r ns name; do
  echo "--- describe pod ${ns}/${name} ---"
  kubectl -n "$ns" describe "pod/${name}" || true
  echo "--- logs ${ns}/${name} ---"
  kubectl -n "$ns" logs "pod/${name}" --all-containers --tail=80 || true
done

echo "=== describe jobs ==="
kubectl get jobs -A --no-headers 2>/dev/null | awk '{print $1, $2}' | while read -r ns name; do
  echo "--- describe job ${ns}/${name} ---"
  kubectl -n "$ns" describe "job/${name}" || true
  echo "--- logs job ${ns}/${name} ---"
  timeout 15 kubectl -n "$ns" logs "job/${name}" --tail=80 || true
done

echo "=== seaweedfs ==="
kubectl -n "$NS" logs deploy/seaweedfs --tail=50 || true

echo "=== events ==="
kubectl get events -A --sort-by=.lastTimestamp | tail -60 || true

echo "=== dnscheck ==="
DNS_POD="dnscheck-$(date +%s)"
timeout 40 kubectl run "$DNS_POD" --rm -i --restart=Never --image=busybox:1.36 -- \
  nslookup kubernetes.default || true
