#!/usr/bin/env bash
set -euo pipefail

NS="${MINIO_NAMESPACE:-kanister}"

kubectl apply -f deploy/namespace.yaml

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: minio-root
  namespace: ${NS}
type: Opaque
stringData:
  rootUser: minio
  rootPassword: minio12345
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: minio/minio:RELEASE.2024-12-18T13-15-44Z
          args: ["server", "/data", "--console-address", ":9001"]
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: minio-root
                  key: rootUser
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: minio-root
                  key: rootPassword
          ports:
            - containerPort: 9000
              name: s3
            - containerPort: 9001
              name: console
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: ${NS}
spec:
  selector:
    app: minio
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
YAML

kubectl -n "$NS" rollout status deploy/minio --timeout=120s
echo "MinIO ready at http://minio.${NS}.svc:9000 (user/pass in secret minio-root)"
echo "Create bucket 'kanister-drills' via mc/console, then point profiles/s3-profile.yaml endpoint there."
