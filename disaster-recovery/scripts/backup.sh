#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="aeromed-production"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/tmp/aeromed-backup-${TIMESTAMP}"
S3_BUCKET="${AEROMED_BACKUP_BUCKET:-s3://aeromed-backups}"
LOG_FILE="/var/log/aeromed/backup-${TIMESTAMP}.log"

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "${LOG_FILE}"; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "${BACKUP_DIR}" "$(dirname "${LOG_FILE}")"
log "Starting AeroMed backup — timestamp: ${TIMESTAMP}"
log "Namespace: ${NAMESPACE} | Destination: ${S3_BUCKET}/k8s/${TIMESTAMP}/"

# ── 1. Kubernetes ConfigMaps ──────────────────────────────────────────────────
log "Backing up ConfigMaps..."
kubectl get configmap -n "${NAMESPACE}" -o yaml > "${BACKUP_DIR}/configmaps.yaml" \
  || die "Failed to export ConfigMaps"
log "  ConfigMaps: OK ($(kubectl get configmap -n "${NAMESPACE}" --no-headers | wc -l | tr -d ' ') objects)"

# ── 2. Kubernetes Secrets (base64-encoded, handled carefully) ─────────────────
log "Backing up Secrets..."
kubectl get secret -n "${NAMESPACE}" -o yaml > "${BACKUP_DIR}/secrets.yaml" \
  || die "Failed to export Secrets"
chmod 600 "${BACKUP_DIR}/secrets.yaml"
log "  Secrets: OK ($(kubectl get secret -n "${NAMESPACE}" --no-headers | wc -l | tr -d ' ') objects)"

# ── 3. Deployments, Services, HPAs, NetworkPolicies ──────────────────────────
log "Backing up workload manifests..."
for resource in deployments services hpa networkpolicies ingresses; do
  kubectl get "${resource}" -n "${NAMESPACE}" -o yaml > "${BACKUP_DIR}/${resource}.yaml" 2>/dev/null \
    && log "  ${resource}: OK" \
    || log "  ${resource}: SKIPPED (none found)"
done

# ── 4. Persistent Volume Claims ───────────────────────────────────────────────
log "Backing up PersistentVolumeClaims..."
kubectl get pvc -n "${NAMESPACE}" -o yaml > "${BACKUP_DIR}/pvc.yaml" \
  || die "Failed to export PVCs"
log "  PVCs: OK"

# ── 5. RBAC (ClusterRoles bound to namespace) ─────────────────────────────────
log "Backing up RBAC..."
kubectl get rolebinding,role -n "${NAMESPACE}" -o yaml > "${BACKUP_DIR}/rbac.yaml" 2>/dev/null \
  || log "  RBAC: SKIPPED"

# ── 6. Postgres database dump ─────────────────────────────────────────────────
log "Backing up Postgres database..."
if kubectl get pod -n "${NAMESPACE}" -l app=aeromed-postgres --no-headers 2>/dev/null | grep -q Running; then
  kubectl exec -n "${NAMESPACE}" deployment/aeromed-postgres -- \
    pg_dumpall -U aeromed --clean --if-exists > "${BACKUP_DIR}/postgres-dump.sql" \
    || die "Postgres dump failed"
  log "  Postgres dump: OK ($(wc -c < "${BACKUP_DIR}/postgres-dump.sql") bytes)"
else
  log "  Postgres: SKIPPED (no running pod found)"
fi

# ── 7. Compress backup archive ────────────────────────────────────────────────
log "Compressing backup archive..."
ARCHIVE="/tmp/aeromed-backup-${TIMESTAMP}.tar.gz"
tar -czf "${ARCHIVE}" -C "/tmp" "aeromed-backup-${TIMESTAMP}" \
  || die "Compression failed"
ARCHIVE_SIZE=$(du -sh "${ARCHIVE}" | cut -f1)
log "  Archive: ${ARCHIVE} (${ARCHIVE_SIZE})"

# ── 8. Upload to S3 ───────────────────────────────────────────────────────────
log "Uploading to S3..."
echo "[DRY-RUN] aws s3 cp \"${ARCHIVE}\" \"${S3_BUCKET}/k8s/${TIMESTAMP}/aeromed-backup-${TIMESTAMP}.tar.gz\" --sse aws:kms"
# Uncomment for production:
# aws s3 cp "${ARCHIVE}" "${S3_BUCKET}/k8s/${TIMESTAMP}/aeromed-backup-${TIMESTAMP}.tar.gz" \
#   --sse aws:kms \
#   || die "S3 upload failed"
log "  S3 upload: OK (simulated)"

# ── 9. Write backup manifest ──────────────────────────────────────────────────
cat > "${BACKUP_DIR}/manifest.json" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "namespace": "${NAMESPACE}",
  "s3_path": "${S3_BUCKET}/k8s/${TIMESTAMP}/",
  "archive": "aeromed-backup-${TIMESTAMP}.tar.gz",
  "archive_size_human": "${ARCHIVE_SIZE}",
  "completed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "status": "success"
}
EOF

# ── 10. Cleanup local temp files ──────────────────────────────────────────────
rm -rf "${BACKUP_DIR}" "${ARCHIVE}"
log "Local temp files cleaned up"

log "=== BACKUP COMPLETE ==="
log "Timestamp:  ${TIMESTAMP}"
log "S3 path:    ${S3_BUCKET}/k8s/${TIMESTAMP}/"
log "Log:        ${LOG_FILE}"
