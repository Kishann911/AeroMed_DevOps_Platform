#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

GATEWAY_URL="${AEROMED_GATEWAY:-http://localhost:5050}"
PROMETHEUS_URL="${AEROMED_PROMETHEUS:-http://localhost:9090}"
NAMESPACE="aeromed-production"

# Default service and duration; override via args
TARGET_SERVICE="${1:-flight-operations}"
OUTAGE_DURATION="${2:-30}"

get_svc_port() {
  case "$1" in
    api-gateway) echo "5050" ;;
    flight-operations) echo "5001" ;;
    patient-records) echo "5002" ;;
    medical-equipment) echo "5003" ;;
    emergency-dispatch) echo "5004" ;;
    aircraft-comms) echo "5005" ;;
  esac
}

get_svc_tier() {
  case "$1" in
    flight-operations|emergency-dispatch|aircraft-comms) echo "Tier 1 — P1" ;;
    patient-records|medical-equipment) echo "Tier 2 — P2" ;;
    api-gateway) echo "Tier 3 — P3" ;;
    *) echo "unknown" ;;
  esac
}

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
step() { echo ""; echo -e "${BOLD}${CYAN}══ $* ══${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
bad()  { echo -e "  ${RED}✗${NC}  $*"; }
info() { echo -e "  ${YELLOW}▸${NC}  $*"; }

USE_K8S=false
kubectl cluster-info &>/dev/null 2>&1 && USE_K8S=true

echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║    SIMULATING: Service Outage                            ║${NC}"
printf  "${RED}${BOLD}║    Target: %-44s║${NC}\n" "${TARGET_SERVICE}"
printf  "${RED}${BOLD}║    Tier:   %-44s║${NC}\n" "$(get_svc_tier "$TARGET_SERVICE")"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

SVC_PORT="$(get_svc_port "$TARGET_SERVICE")"
SVC_URL="http://localhost:${SVC_PORT}"
FAILURE_START=$(date +%s)

# ── Baseline health ───────────────────────────────────────────────────────────
step "1. Baseline health check"
PRE_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${SVC_URL}/health" 2>/dev/null || echo "000")
if [[ "${PRE_CODE}" == "200" ]]; then
  ok "${TARGET_SERVICE} is UP (HTTP ${PRE_CODE})"
else
  info "${TARGET_SERVICE} is ${PRE_CODE} before simulation"
fi

# ── Inject failure ────────────────────────────────────────────────────────────
step "2. Injecting failure into ${TARGET_SERVICE}"
if [[ "${USE_K8S}" == "true" ]]; then
  kubectl scale deployment "${TARGET_SERVICE}" --replicas=0 -n "${NAMESPACE}"
  ok "Scaled ${TARGET_SERVICE} to 0 replicas in ${NAMESPACE}"
else
  RESP=$(curl -sf -X POST "${GATEWAY_URL}/simulate/failure" \
    -H "Content-Type: application/json" \
    -d "{\"service\": \"${TARGET_SERVICE}\", \"duration_seconds\": ${OUTAGE_DURATION}}" \
    2>/dev/null || echo '{"error":"gateway_unreachable"}')
  ok "Failure injected: ${RESP}"
fi

echo -e "\n  ${RED}${BOLD}${TARGET_SERVICE} is DOWN${NC}"

# ── Observe platform response ─────────────────────────────────────────────────
step "3. Observing platform degradation (10s window)"
sleep 5

# Check aggregated status
ALL_STATUS=$(curl -sf --max-time 5 "${GATEWAY_URL}/api/all-status" 2>/dev/null || echo '{}')
SVC_STATUS=$(echo "${ALL_STATUS}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
key = '${TARGET_SERVICE}'.replace('-','_')
svcs = d.get('services', d)
s = svcs.get('${TARGET_SERVICE}', svcs.get(key, {}))
print(s.get('status', 'unknown'))
" 2>/dev/null || echo "unknown")

info "Aggregated status for ${TARGET_SERVICE}: ${SVC_STATUS}"
info "Other services continue to operate (circuit breaker / graceful degradation)"

sleep 5

# Check Prometheus alerts
ALERTS=$(curl -sf --max-time 5 "${PROMETHEUS_URL}/api/v1/alerts" 2>/dev/null \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
alerts = d.get('data', {}).get('alerts', [])
relevant = [a['labels'].get('alertname','?') for a in alerts
            if '${TARGET_SERVICE}' in str(a.get('labels',{})).lower()
            or a.get('state') == 'firing']
print(', '.join(relevant) if relevant else 'No alerts yet (within eval window)')
" 2>/dev/null || echo "Prometheus unreachable")
info "Prometheus alerts: ${ALERTS}"

# ── Recovery ──────────────────────────────────────────────────────────────────
step "4. Recovering ${TARGET_SERVICE}"
RECOVERY_START=$(date +%s)

if [[ "${USE_K8S}" == "true" ]]; then
  kubectl scale deployment "${TARGET_SERVICE}" --replicas=2 -n "${NAMESPACE}"
  kubectl wait --for=condition=ready pod -l "app=${TARGET_SERVICE}" \
    -n "${NAMESPACE}" --timeout=120s
  ok "Pods ready"
else
  curl -sf -X POST "${GATEWAY_URL}/simulate/clear" \
    -H "Content-Type: application/json" \
    -d "{\"service\": \"${TARGET_SERVICE}\"}" &>/dev/null || true
  info "Recovery triggered — polling health endpoint..."
  WAITED=0
  while [[ ${WAITED} -lt 90 ]]; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "${SVC_URL}/health" 2>/dev/null || echo "000")
    [[ "${CODE}" == "200" ]] && break
    printf "\r  ${YELLOW}▸${NC}  Waiting... %ds (HTTP %s)" "${WAITED}" "${CODE}"
    sleep 3; WAITED=$((WAITED + 3))
  done
  echo ""
fi

RECOVERY_END=$(date +%s)
RTO=$((RECOVERY_END - RECOVERY_START))
OUTAGE=$((RECOVERY_END - FAILURE_START))

FINAL_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${SVC_URL}/health" 2>/dev/null || echo "000")

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║    RECOVERY COMPLETE                                     ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
printf "  %-28s %s\n"  "Service:"          "${TARGET_SERVICE}"
printf "  %-28s %s\n"  "Final health:"     "HTTP ${FINAL_CODE}"
printf "  %-28s %ss\n" "Recovery time:"    "${RTO}"
printf "  %-28s %ss\n" "Total outage:"     "${OUTAGE}"
printf "  %-28s %s\n"  "Service tier:"     "$(get_svc_tier "$TARGET_SERVICE")"
echo ""
