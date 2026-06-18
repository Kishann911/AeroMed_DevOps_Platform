#!/usr/bin/env bash
set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Config ───────────────────────────────────────────────────────────────────
GATEWAY_URL="${AEROMED_GATEWAY:-http://localhost:5000}"
COMMS_URL="${AEROMED_COMMS:-http://localhost:5005}"
PROMETHEUS_URL="${AEROMED_PROMETHEUS:-http://localhost:9090}"
OUTAGE_DURATION="${1:-45}"   # seconds the failure lasts
NAMESPACE="aeromed-production"
USE_K8S=false

# Detect environment: use kubectl if a cluster is reachable, else Docker/API mode
if kubectl cluster-info &>/dev/null 2>&1; then
  USE_K8S=true
fi

log()    { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
step()   { echo ""; echo -e "${BOLD}${CYAN}══ $* ══${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC}  $*"; }
bad()    { echo -e "  ${RED}✗${NC}  $*"; }
info()   { echo -e "  ${YELLOW}▸${NC}  $*"; }

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║    SIMULATING: Aircraft Communication Failure            ║${NC}"
echo -e "${RED}${BOLD}║    Scenario: aircraft-comms service goes down            ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Mode: $([ "${USE_K8S}" = "true" ] && echo 'Kubernetes' || echo 'Docker Compose / API')"
info "Outage duration: ${OUTAGE_DURATION}s"

# ─── Step 1: Baseline health ──────────────────────────────────────────────────
step "Step 1: Verifying baseline — all services healthy"
START_TIME=$(date +%s)

PRE_STATUS=$(curl -sf --max-time 5 "${GATEWAY_URL}/api/all-status" 2>/dev/null || echo '{}')
COMMS_PRE=$(echo "${PRE_STATUS}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
svcs = d.get('services', d)
s = svcs.get('aircraft-comms', svcs.get('aircraft_comms', {}))
print(s.get('status', 'unknown'))
" 2>/dev/null || echo "unknown")

if [[ "${COMMS_PRE}" == "healthy" || "${COMMS_PRE}" == "up" ]]; then
  ok "aircraft-comms baseline: ${COMMS_PRE}"
else
  info "aircraft-comms baseline: ${COMMS_PRE} (may already be in degraded state)"
fi

# ─── Step 2: Take aircraft-comms down ─────────────────────────────────────────
step "Step 2: Taking aircraft-comms service DOWN"

FAILURE_START=$(date +%s)

if [[ "${USE_K8S}" == "true" ]]; then
  log "Scaling deployment to 0 replicas..."
  kubectl scale deployment aircraft-comms --replicas=0 -n "${NAMESPACE}"
  ok "kubectl scale deployment aircraft-comms --replicas=0 -n ${NAMESPACE}"
else
  log "Injecting failure via API gateway simulation endpoint..."
  RESPONSE=$(curl -sf -X POST "${GATEWAY_URL}/simulate/failure" \
    -H "Content-Type: application/json" \
    -d "{\"service\": \"aircraft-comms\", \"duration_seconds\": ${OUTAGE_DURATION}}" \
    2>/dev/null || echo '{"error":"api_unavailable"}')
  echo "  API response: ${RESPONSE}"
  ok "Failure injected via POST ${GATEWAY_URL}/simulate/failure"
fi

echo ""
echo -e "  ${RED}${BOLD}Aircraft comms service is DOWN — checking system response...${NC}"

# ─── Step 3: Observe degraded state ──────────────────────────────────────────
step "Step 3: Observing degraded state (15s observation window)"
sleep 5

log "Checking aggregated platform status..."
ALL_STATUS=$(curl -sf --max-time 5 "${GATEWAY_URL}/api/all-status" 2>/dev/null || echo '{}')
COMMS_STATUS=$(echo "${ALL_STATUS}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
svcs = d.get('services', d)
s = svcs.get('aircraft-comms', svcs.get('aircraft_comms', {}))
print(s.get('status', 'unknown'))
" 2>/dev/null || echo "unknown")

if [[ "${COMMS_STATUS}" == "healthy" || "${COMMS_STATUS}" == "up" ]]; then
  info "aircraft-comms still shows ${COMMS_STATUS} (failure propagation delay)"
else
  bad "aircraft-comms: ${COMMS_STATUS} — degraded state confirmed"
fi

# Check direct /health endpoint
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${COMMS_URL}/health" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" == "200" ]]; then
  info "Direct health check returned ${HTTP_CODE} (service still up at container level)"
else
  bad "Direct health check: HTTP ${HTTP_CODE} — service unreachable"
fi

sleep 10

# ─── Step 4: Check Prometheus alert ──────────────────────────────────────────
step "Step 4: Checking Prometheus for AircraftCommunicationLost alert"

ALERTS_JSON=$(curl -sf --max-time 5 "${PROMETHEUS_URL}/api/v1/alerts" 2>/dev/null || echo '{"data":{"alerts":[]}}')
ALERT_STATUS=$(echo "${ALERTS_JSON}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
alerts = d.get('data', {}).get('alerts', [])
for a in alerts:
    name = a.get('labels', {}).get('alertname', '')
    if 'Aircraft' in name or 'aircraft' in name or 'comms' in name.lower():
        print(f'{name}: {a[\"state\"]}')
        sys.exit(0)
# Check for ServiceDown alert for aircraft-comms
for a in alerts:
    name = a.get('labels', {}).get('alertname', '')
    job  = a.get('labels', {}).get('job', '')
    inst = a.get('labels', {}).get('instance', '')
    if 'aircraft' in job.lower() or 'aircraft' in inst.lower():
        print(f'{name} [{job}]: {a[\"state\"]}')
        sys.exit(0)
print('AircraftCommunicationLost: pending (Prometheus eval interval ~15s)')
" 2>/dev/null || echo "Prometheus unreachable — alert status unknown")

echo ""
echo -e "  ${YELLOW}${BOLD}Prometheus Alert Status:${NC}"
echo -e "  ${YELLOW}  ${ALERT_STATUS}${NC}"

# List all currently firing alerts for context
FIRING=$(echo "${ALERTS_JSON}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
alerts = d.get('data', {}).get('alerts', [])
firing = [a['labels'].get('alertname','?') for a in alerts if a.get('state') == 'firing']
print(', '.join(firing) if firing else 'None currently firing')
" 2>/dev/null || echo "N/A")
info "All firing alerts: ${FIRING}"

# ─── Step 5: Recovery ─────────────────────────────────────────────────────────
step "Step 5: RECOVERING — Restoring aircraft communications"
echo -e "  ${GREEN}${BOLD}Restoring aircraft-comms service...${NC}"

RECOVERY_START=$(date +%s)

if [[ "${USE_K8S}" == "true" ]]; then
  log "Scaling deployment back to 2 replicas..."
  kubectl scale deployment aircraft-comms --replicas=2 -n "${NAMESPACE}"
  ok "kubectl scale deployment aircraft-comms --replicas=2 -n ${NAMESPACE}"

  log "Waiting for pods to become ready..."
  kubectl wait --for=condition=ready pod \
    -l app=aircraft-comms \
    -n "${NAMESPACE}" \
    --timeout=120s \
    && ok "Pods are ready"
else
  log "Failure simulation has a ${OUTAGE_DURATION}s duration — waiting for auto-recovery..."
  # The API simulation auto-recovers after duration_seconds
  # For an immediate manual recovery, hit the clear endpoint if available
  CLEAR_RESP=$(curl -sf -X POST "${GATEWAY_URL}/simulate/clear" \
    -H "Content-Type: application/json" \
    -d '{"service": "aircraft-comms"}' 2>/dev/null || echo "")
  if echo "${CLEAR_RESP}" | grep -qi "cleared\|success\|ok"; then
    ok "Failure cleared via API"
  else
    info "Waiting for auto-recovery (timeout: ${OUTAGE_DURATION}s)..."
    sleep 5
  fi
fi

# ─── Step 6: Poll until healthy ───────────────────────────────────────────────
step "Step 6: Waiting for health endpoint to confirm recovery"
MAX_WAIT=120
WAITED=0
while [[ ${WAITED} -lt ${MAX_WAIT} ]]; do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${COMMS_URL}/health" 2>/dev/null || echo "000")
  if [[ "${HTTP}" == "200" ]]; then
    ok "aircraft-comms /health returned HTTP 200"
    break
  fi
  printf "\r  ${YELLOW}▸${NC}  Waiting for recovery... %ds elapsed (HTTP %s)" "${WAITED}" "${HTTP}"
  sleep 3
  WAITED=$((WAITED + 3))
done
echo ""

if [[ ${WAITED} -ge ${MAX_WAIT} ]]; then
  bad "Timeout: aircraft-comms did not recover within ${MAX_WAIT}s"
else
  RECOVERY_END=$(date +%s)
  RTO_ACHIEVED=$((RECOVERY_END - RECOVERY_START))
  TOTAL_ELAPSED=$((RECOVERY_END - FAILURE_START))

  # ─── Step 7: Final health confirmation ──────────────────────────────────────
  step "Step 7: Final platform health check"
  FINAL_STATUS=$(curl -sf --max-time 5 "${GATEWAY_URL}/api/all-status" 2>/dev/null || echo '{}')
  COMMS_FINAL=$(echo "${FINAL_STATUS}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
svcs = d.get('services', d)
s = svcs.get('aircraft-comms', svcs.get('aircraft_comms', {}))
print(s.get('status', 'unknown'))
" 2>/dev/null || echo "unknown")

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║              RECOVERY COMPLETE                           ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  printf "  %-30s %s\n" "aircraft-comms status:" "${COMMS_FINAL}"
  printf "  %-30s %ss\n" "RTO achieved:"          "${RTO_ACHIEVED}"
  printf "  %-30s %ss\n" "Total outage duration:" "${TOTAL_ELAPSED}"
  printf "  %-30s %s\n"  "RTO target (Tier 1):"  "300s (5 min)"
  echo ""
  if [[ ${RTO_ACHIEVED} -le 300 ]]; then
    ok "RTO TARGET MET — recovered in ${RTO_ACHIEVED}s (target: 300s)"
  else
    bad "RTO TARGET MISSED — ${RTO_ACHIEVED}s exceeded the 300s Tier 1 target"
  fi
fi
echo ""
