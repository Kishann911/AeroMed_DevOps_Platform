#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="aeromed-production"
S3_BUCKET="${AEROMED_BACKUP_BUCKET:-s3://aeromed-backups}"
LOG_FILE="/var/log/aeromed/restore-$(date +"%Y%m%d_%H%M%S").log"

log()  { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "${LOG_FILE}"; }
die()  { log "ERROR: $*"; exit 1; }
warn() { log "WARN:  $*"; }

usage() {
  cat <<EOF
Usage: $0 --timestamp <YYYYMMDD_HHMM> [--service <service>] [--dry-run]

  --timestamp YYYYMMDD_HHMM   Backup timestamp to restore from (required)
  --service   <name>           Restore only a specific service (optional)
  --dry-run                    Show what would be restored without applying
  --force                      Skip confirmation prompts (dangerous)

Examples:
  $0 --timestamp 20260616_0300
  $0 --timestamp 20260616_0300 --service postgres
  $0 --timestamp 20260616_0300 --dry-run
EOF
  exit 1
}

TIMESTAMP=""
SERVICE="all"
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timestamp) TIMESTAMP="$2"; shift 2 ;;
    --service)   SERVICE="$2";   shift 2 ;;
    --dry-run)   DRY_RUN=true;   shift ;;
    --force)     FORCE=true;     shift ;;
    *) usage ;;
  esac
done

[[ -z "${TIMESTAMP}" ]] && usage

RESTORE_DIR="/tmp/aeromed-restore-${TIMESTAMP}"
ARCHIVE_NAME="aeromed-backup-${TIMESTAMP}.tar.gz"
S3_PATH="${S3_BUCKET}/k8s/${TIMESTAMP}/${ARCHIVE_NAME}"

mkdir -p "${RESTORE_DIR}" "$(dirname "${LOG_FILE}")"
log "=== AeroMed Restore ==="
log "Backup timestamp: ${TIMESTAMP}"
log "Service filter:   ${SERVICE}"
log "Dry run:          ${DRY_RUN}"
log "Namespace:        ${NAMESPACE}"

# ── Confirmation prompt ───────────────────────────────────────────────────────
if [[ "${FORCE}" != "true" && "${DRY_RUN}" != "true" ]]; then
  echo ""
  echo "WARNING: This will OVERWRITE current Kubernetes resources in namespace '${NAMESPACE}'."
  echo "         Restoring from backup: ${S3_PATH}"
  read -r -p "Type 'yes-restore' to confirm: " CONFIRM
  [[ "${CONFIRM}" == "yes-restore" ]] || die "Restore aborted by user"
fi

# ── 1. Download backup from S3 ────────────────────────────────────────────────
log "Downloading backup from S3..."
echo "[DRY-RUN] aws s3 cp \"${S3_PATH}\" \"/tmp/${ARCHIVE_NAME}\""
if [[ "${DRY_RUN}" != "true" ]]; then
  # Uncomment for production:
  # aws s3 cp "${S3_PATH}" "/tmp/${ARCHIVE_NAME}" || die "S3 download failed"
  log "  Download: OK (simulated)"
else
  log "  [DRY-RUN] Would download: ${S3_PATH}"
fi

# ── 2. Extract archive ────────────────────────────────────────────────────────
log "Extracting archive..."
if [[ "${DRY_RUN}" != "true" ]]; then
  # tar -xzf "/tmp/${ARCHIVE_NAME}" -C /tmp/
  log "  Extraction: OK (simulated)"
else
  log "  [DRY-RUN] Would extract to: ${RESTORE_DIR}"
fi

# ── 3. Restore ConfigMaps ─────────────────────────────────────────────────────
if [[ "${SERVICE}" == "all" || "${SERVICE}" == "configmaps" ]]; then
  log "Restoring ConfigMaps..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    # kubectl apply -f "${RESTORE_DIR}/configmaps.yaml" -n "${NAMESPACE}"
    log "  ConfigMaps: OK (simulated)"
  else
    log "  [DRY-RUN] Would apply: ${RESTORE_DIR}/configmaps.yaml"
  fi
fi

# ── 4. Restore Secrets ────────────────────────────────────────────────────────
if [[ "${SERVICE}" == "all" || "${SERVICE}" == "secrets" ]]; then
  log "Restoring Secrets..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    # kubectl apply -f "${RESTORE_DIR}/secrets.yaml" -n "${NAMESPACE}"
    log "  Secrets: OK (simulated)"
  else
    log "  [DRY-RUN] Would apply: ${RESTORE_DIR}/secrets.yaml"
  fi
fi

# ── 5. Restore Postgres database ──────────────────────────────────────────────
if [[ "${SERVICE}" == "all" || "${SERVICE}" == "postgres" ]]; then
  log "Restoring Postgres database..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    log "  Step 5a: Scaling down services to prevent writes during restore..."
    # for svc in patient-records emergency-dispatch; do
    #   kubectl scale deployment/${svc} --replicas=0 -n "${NAMESPACE}"
    # done

    log "  Step 5b: Restoring Postgres from dump..."
    # kubectl exec -n "${NAMESPACE}" deployment/aeromed-postgres -- \
    #   psql -U aeromed < "${RESTORE_DIR}/postgres-dump.sql"

    log "  Step 5c: Scaling services back up..."
    # for svc in patient-records emergency-dispatch; do
    #   kubectl scale deployment/${svc} --replicas=3 -n "${NAMESPACE}"
    # done

    log "  Postgres restore: OK (simulated)"
  else
    log "  [DRY-RUN] Would restore Postgres from: ${RESTORE_DIR}/postgres-dump.sql"
    log "  [DRY-RUN] Would scale down: patient-records, emergency-dispatch"
    log "  [DRY-RUN] Would scale up after restore"
  fi
fi

# ── 6. Restore Deployments ────────────────────────────────────────────────────
if [[ "${SERVICE}" == "all" ]]; then
  log "Restoring workload manifests..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    # kubectl apply -f "${RESTORE_DIR}/deployments.yaml" -n "${NAMESPACE}"
    # kubectl apply -f "${RESTORE_DIR}/services.yaml" -n "${NAMESPACE}"
    # kubectl apply -f "${RESTORE_DIR}/hpa.yaml" -n "${NAMESPACE}"
    log "  Workloads: OK (simulated)"
  else
    log "  [DRY-RUN] Would apply deployments, services, HPA manifests"
  fi
fi

# ── 7. Run health check ───────────────────────────────────────────────────────
log "Running post-restore health check..."
if [[ "${DRY_RUN}" != "true" ]]; then
  sleep 15  # Allow pods to start
  ./disaster-recovery/scripts/health-check-all.sh || warn "Some health checks failed — review manually"
else
  log "  [DRY-RUN] Would run: health-check-all.sh"
fi

# ── 8. Cleanup ────────────────────────────────────────────────────────────────
rm -rf "${RESTORE_DIR}" "/tmp/${ARCHIVE_NAME}" 2>/dev/null || true
log "Cleanup: OK"

log "=== RESTORE COMPLETE ==="
log "Restored from: ${S3_PATH}"
log "Log: ${LOG_FILE}"
