#!/usr/bin/env bash
set -euo pipefail

PRIMARY_CONTEXT="${AEROMED_PRIMARY_CONTEXT:-aeromed-production}"
DR_CONTEXT="${AEROMED_DR_CONTEXT:-aeromed-dr}"
NAMESPACE="aeromed-production"
MANIFESTS_DIR="$(dirname "$0")/../../kubernetes"
LOG_FILE="/var/log/aeromed/failover-$(date +"%Y%m%d_%H%M%S").log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TARGET="${1:-dr}"  # 'dr' for primary→DR failover, 'primary' for DR→primary failback

log()  { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "${LOG_FILE}"; }
die()  { log "ERROR: $*"; send_alert "FAILOVER FAILED: $*"; exit 1; }
warn() { log "WARN:  $*"; }

send_alert() {
  local msg="$1"
  log "ALERT: ${msg}"
  # Production: post to Slack webhook
  # curl -s -X POST "${SLACK_WEBHOOK_URL}" \
  #   -H 'Content-type: application/json' \
  #   --data "{\"text\":\"[AeroMed Failover] ${msg}\"}"
  echo "[ALERT STUB] ${msg}"
}

mkdir -p "$(dirname "${LOG_FILE}")"

log "==================================================================="
log "AeroMed Cluster Failover Script"
log "Direction:  ${TARGET}"
log "Timestamp:  ${TIMESTAMP}"
log "Primary:    ${PRIMARY_CONTEXT}"
log "DR cluster: ${DR_CONTEXT}"
log "==================================================================="

send_alert "FAILOVER INITIATED at ${TIMESTAMP} — direction: ${TARGET}"

# ── Step 1: Check primary cluster health ─────────────────────────────────────
log "Step 1: Checking primary cluster health..."
if kubectl cluster-info --context="${PRIMARY_CONTEXT}" &>/dev/null; then
  PRIMARY_HEALTHY=true
  log "  Primary cluster: REACHABLE"
else
  PRIMARY_HEALTHY=false
  log "  Primary cluster: UNREACHABLE — confirming DR failover is warranted"
fi

if [[ "${TARGET}" == "primary" && "${PRIMARY_HEALTHY}" != "true" ]]; then
  die "Cannot failback to primary — primary cluster is still unreachable"
fi

# ── Step 2: Switch kubectl context to target cluster ─────────────────────────
log "Step 2: Switching kubectl context..."
if [[ "${TARGET}" == "dr" ]]; then
  TARGET_CONTEXT="${DR_CONTEXT}"
else
  TARGET_CONTEXT="${PRIMARY_CONTEXT}"
fi

kubectl config use-context "${TARGET_CONTEXT}" \
  || die "Failed to switch kubectl context to ${TARGET_CONTEXT}"
log "  Active context: $(kubectl config current-context)"

# ── Step 3: Verify target cluster nodes are ready ────────────────────────────
log "Step 3: Verifying target cluster node readiness..."
NOT_READY=$(kubectl get nodes --no-headers | grep -v "Ready" | grep -v "NotReady.*SchedulingDisabled" | wc -l | tr -d ' ')
TOTAL=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
log "  Nodes ready: $((TOTAL - NOT_READY))/${TOTAL}"

if [[ "${NOT_READY}" -gt 0 ]]; then
  warn "${NOT_READY} node(s) not ready in target cluster — proceeding anyway"
fi

# ── Step 4: Ensure namespace exists in target cluster ────────────────────────
log "Step 4: Ensuring namespace '${NAMESPACE}' exists in target cluster..."
kubectl get namespace "${NAMESPACE}" &>/dev/null \
  || kubectl create namespace "${NAMESPACE}"
log "  Namespace: OK"

# ── Step 5: Apply all Kubernetes manifests to target cluster ─────────────────
log "Step 5: Applying Kubernetes manifests to target cluster..."

for dir in namespaces configmaps secrets deployments services hpa ingress rbac network-policies; do
  manifest_path="${MANIFESTS_DIR}/${dir}"
  if [[ -d "${manifest_path}" ]]; then
    log "  Applying ${dir}..."
    kubectl apply -f "${manifest_path}/" -n "${NAMESPACE}" --timeout=60s \
      || warn "  Some ${dir} manifests failed to apply — check manually"
  else
    log "  ${dir}: directory not found, skipping"
  fi
done

log "  Manifests applied"

# ── Step 6: Wait for pods to become ready ────────────────────────────────────
log "Step 6: Waiting for pods to become ready (timeout: 180s)..."
TIMEOUT=180
ELAPSED=0
while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
  NOT_READY_PODS=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l | tr -d ' ')
  TOTAL_PODS=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  log "  Pods ready: $((TOTAL_PODS - NOT_READY_PODS))/${TOTAL_PODS} (${ELAPSED}s elapsed)"
  [[ "${NOT_READY_PODS}" -eq 0 && "${TOTAL_PODS}" -gt 0 ]] && break
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
  warn "Timeout waiting for all pods — some may still be starting"
fi

# ── Step 7: Update DNS / load balancer ───────────────────────────────────────
log "Step 7: Updating DNS to point to target cluster..."
# Production: update Route53 health check or CNAME
# aws route53 change-resource-record-sets \
#   --hosted-zone-id "${HOSTED_ZONE_ID}" \
#   --change-batch file://dns-failover-${TARGET}.json
echo "[DNS STUB] Route53 / load balancer DNS update would be executed here"
echo "[DNS STUB] TTL: 60s — DNS propagation expected within 60 seconds"
log "  DNS update: OK (simulated)"

# ── Step 8: Run health check ─────────────────────────────────────────────────
log "Step 8: Running health checks against target cluster..."
sleep 5
"$(dirname "$0")/health-check-all.sh" || warn "Some health checks failed — review before declaring recovery complete"

# ── Step 9: Log and notify all teams ─────────────────────────────────────────
DURATION=$(($(date +%s) - $(date -d "${TIMESTAMP}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${TIMESTAMP}" +%s 2>/dev/null || echo "0")))
log "==================================================================="
log "FAILOVER COMPLETE"
log "Direction:      ${TARGET}"
log "Active cluster: ${TARGET_CONTEXT}"
log "Completed at:   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log "Log:            ${LOG_FILE}"
log "==================================================================="

send_alert "FAILOVER COMPLETE — Active cluster: ${TARGET_CONTEXT} | Direction: ${TARGET} | See log: ${LOG_FILE}"
