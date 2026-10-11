#!/usr/bin/env bash
# Bind recovery-contract-operator-drill ClusterRole into a namespace via RoleBinding.
set -euo pipefail
NS="${1:?namespace required}"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: recovery-contract-operator-drill
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: kanister-backup-restore
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: recovery-contract-operator-drill
subjects:
  - kind: ServiceAccount
    name: recovery-contract-operator
    namespace: kanister
YAML
echo "RoleBinding recovery-contract-operator-drill ready in ${NS}"
