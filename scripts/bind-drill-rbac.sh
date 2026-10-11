#!/usr/bin/env bash
# Bind drill ClusterRoles into a namespace via RoleBinding (never ClusterRoleBinding).
# Binds both recovery-contract-operator-drill and kanister-operator-drill.
set -euo pipefail
NS="${1:?namespace required}"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

bind_one() {
  local name="$1"
  local sa_name="$2"
  local sa_ns="$3"
  local role="$4"
  kubectl apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: kanister-backup-restore
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${role}
subjects:
  - kind: ServiceAccount
    name: ${sa_name}
    namespace: ${sa_ns}
YAML
}

bind_one recovery-contract-operator-drill recovery-contract-operator kanister recovery-contract-operator-drill
bind_one kanister-operator-drill kanister-operator kanister kanister-operator-drill
echo "RoleBindings ready in ${NS} for recovery-contract-operator + kanister-operator"
