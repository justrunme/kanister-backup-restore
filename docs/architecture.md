# Architecture

Application Recovery Contract for **Postgres + S3**:

1. **Linked state** — `app_manifest.generation` and `app_objects(object_key, sha256, generation)` reference objects in the SeaweedFS/MinIO bucket.
2. **Recovery point** — one `rp-id` binds a Kanister Postgres backup (unique key + sha256) with copied S3 objects and `manifest.json` (timestamps, generation, object list).
3. **Drill** — restore Postgres into an unseeded namespace (ResourceQuota/LimitRange) and pull RP objects; PROVE runs cross-component consistency.
4. **CRDs** — `RecoveryContract` (targets, RTO/RPO, evidence TTL, schedule) and `RecoveryDrill` (status: verdict, last success, evidence digest) reconciled by a kopf operator.
5. **Future** — Solr indexing as an additional component (not implemented).
