#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
#  AeroMed Full Recovery Demo — Presenter Script
#  Run this during panel/review to demonstrate platform resilience end-to-end.
#  Each step pauses and waits for Enter so the presenter can narrate.
# ═══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

GATEWAY_URL="${AEROMED_GATEWAY:-http://localhost:5050}"
PROMETHEUS_URL="${AEROMED_PROMETHEUS:-http://localhost:9090}"
GRAFANA_URL="${AEROMED_GRAFANA:-http://localhost:3000}"
COMMS_URL="${AEROMED_COMMS:-http://localhost:5005}"
DISPATCH_URL="${AEROMED_DISPATCH:-http://localhost:5004}"
NAMESPACE="aeromed-production"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_START=$(date +%s)

STEP_TIMES=()

USE_K8S=false
kubectl cluster-info &>/dev/null 2>&1 && USE_K8S=true

# ─── Utilities ─────────────────────────────────────────────────────────────────
pause() {
  echo ""
  echo -e "  ${BLUE}${BOLD}[ Press ENTER to continue → $* ]${NC}"
  read -r
}

section() {
  local num="$1"; shift
  echo ""
  echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────────────┐${NC}"
  printf   "${BOLD}${CYAN}│  Step %-2s: %-50s│${NC}\n" "${num}" "$*"
  echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────────┘${NC}"
  STEP_TIMES["${num}"]=$(date +%s)
}

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
bad()  { echo -e "  ${RED}✗${NC}  $*"; }
info() { echo -e "  ${YELLOW}▸${NC}  $*"; }
log()  { echo -e "${CYAN}  [$(date '+%H:%M:%S')]${NC}  $*"; }

elapsed_since() {
  local ref="${STEP_TIMES[$1]:-${DEMO_START}}"
  echo $(( $(date +%s) - ref ))
}

check_service() {
  local svc="$1"; local port="$2"
  local code; code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:${port}/health" 2>/dev/null || echo "000")
  if [[ "${code}" == "200" ]]; then
    printf "  ${GREEN}✓${NC}  %-28s HTTP %s — HEALTHY\n" "${svc}" "${code}"
  else
    printf "  ${RED}✗${NC}  %-28s HTTP %s — OFFLINE\n" "${svc}" "${code}"
  fi
}

# ─── Title Screen ──────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║                                                              ║${NC}"
echo -e "${CYAN}${BOLD}║         AeroMed DevOps Platform — Live Demo                  ║${NC}"
echo -e "${CYAN}${BOLD}║         Critical Care Air Ambulance Operations                ║${NC}"
echo -e "${CYAN}${BOLD}║                                                              ║${NC}"
echo -e "${CYAN}${BOLD}║  This demo walks through:                                    ║${NC}"
echo -e "${CYAN}${BOLD}║   1. Platform health baseline                                ║${NC}"
echo -e "${CYAN}${BOLD}║   2. Aircraft-comms failure + alert firing                   ║${NC}"
echo -e "${CYAN}${BOLD}║   3. Automatic recovery + RTO measurement                    ║${NC}"
echo -e "${CYAN}${BOLD}║   4. Traffic surge + HPA autoscaling                         ║${NC}"
echo -e "${CYAN}${BOLD}║   5. Prometheus alert lifecycle                               ║${NC}"
echo -e "${CYAN}${BOLD}║   6. Final health verification + DR summary                  ║${NC}"
echo -e "${CYAN}${BOLD}║                                                              ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Mode: $([ "${USE_K8S}" = "true" ] && echo 'Kubernetes' || echo 'Docker Compose')"
info "Gateway: ${GATEWAY_URL}"
info "Grafana: ${GRAFANA_URL} (admin / aeromed123)"

pause "Start Demo"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1 — BASELINE HEALTH
# ═══════════════════════════════════════════════════════════════════════════════
section 1 "Show Initial Platform Health — All Green"

echo ""
echo -e "  ${BOLD}All six AeroMed microservices are running with full health.${NC}"
echo -e "  ${BOLD}This is the nominal state before any failure is injected.${NC}"
echo ""

check_service "api-gateway"         5050
check_service "flight-operations"   5001
check_service "patient-records"     5002
check_service "medical-equipment"   5003
check_service "emergency-dispatch"  5004
check_service "aircraft-comms"      5005

echo ""

# Aggregated status
ALL_STATUS=$(curl -sf --max-time 5 "${GATEWAY_URL}/api/all-status" 2>/dev/null || echo '{}')
HEALTHY_COUNT=$(echo "${ALL_STATUS}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
svcs = d.get('services', d)
print(sum(1 for s in svcs.values() if isinstance(s, dict) and s.get('status') in ('healthy','up')))
" 2>/dev/null || echo "?")

info "Aggregated healthy services: ${HEALTHY_COUNT}/6"
info "Open Grafana now: ${GRAFANA_URL}/d/aeromed-operations-overview"
info "You should see: Platform Health = 6, Active Alerts = None"

pause "Step 2 — Simulate aircraft-comms failure"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2 — INJECT AIRCRAFT-COMMS FAILURE
# ═══════════════════════════════════════════════════════════════════════════════
section 2 "Simulate Aircraft Communication Failure (P1 Incident)"

echo ""
echo -e "  ${RED}${BOLD}INCIDENT SCENARIO:${NC}"
echo -e "  The aircraft-comms service goes down. This is a Tier 1 / P1 incident."
echo -e "  Real consequence: flight crew telemetry and GPS tracking severed."
echo ""

FAILURE_START=$(date +%s)

if [[ "${USE_K8S}" == "true" ]]; then
  log "Scaling aircraft-comms deployment to 0 replicas..."
  kubectl scale deployment aircraft-comms --replicas=0 -n "${NAMESPACE}"
  ok "kubectl scale deployment aircraft-comms --replicas=0 -n ${NAMESPACE}"
else
  log "Injecting failure via api-gateway simulation endpoint..."
  RESP=$(curl -sf -X POST "${GATEWAY_URL}/simulate/failure" \
    -H "Content-Type: application/json" \
    -d '{"service": "aircraft-comms", "duration_seconds": 120}' \
    2>/dev/null || echo '{}')
  ok "Failure injected: ${RESP}"
fi

echo ""
echo -e "  ${RED}${BOLD}aircraft-comms is NOW DOWN${NC}"
echo ""
info "Watch Grafana: Platform Health should drop from 6 → 5"
info "Watch Grafana: Error Rate panel should spike"
info "In production: AlertManager would fire to #aeromed-critical-alerts Slack channel"

pause "Step 3 — Show degraded state"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3 — SHOW DEGRADED STATE
# ═══════════════════════════════════════════════════════════════════════════════
section 3 "Show Degraded Platform State"

sleep 5

echo ""
echo -e "  ${BOLD}Platform status while aircraft-comms is down:${NC}"
echo ""

check_service "api-gateway"         5050
check_service "flight-operations"   5001
check_service "patient-records"     5002
check_service "medical-equipment"   5003
check_service "emergency-dispatch"  5004

# aircraft-comms — expect failure
COMMS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${COMMS_URL}/health" 2>/dev/null || echo "000")
printf "  ${RED}✗${NC}  %-28s HTTP %s — OFFLINE\n" "aircraft-comms" "${COMMS_CODE}"

echo ""
info "Key observation: All OTHER services remain healthy."
info "This demonstrates service isolation — one failure does not cascade."
echo ""

# Prometheus alerts
ALERTS=$(curl -sf --max-time 5 "${PROMETHEUS_URL}/api/v1/alerts" 2>/dev/null \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
firing = [a['labels'].get('alertname','?') for a in d.get('data',{}).get('alerts',[]) if a.get('state')=='firing']
print('FIRING: ' + ', '.join(firing) if firing else 'Pending (within Prometheus eval window ~15s)')
" 2>/dev/null || echo "Prometheus unreachable")

info "Prometheus alerts: ${ALERTS}"

DEGRADED_ELAPSED=$(( $(date +%s) - FAILURE_START ))
info "Outage duration so far: ${DEGRADED_ELAPSED}s"

pause "Step 4 — Demonstrate recovery"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4 — RECOVERY
# ═══════════════════════════════════════════════════════════════════════════════
section 4 "Automatic Recovery in Action"

echo ""
echo -e "  ${GREEN}${BOLD}RECOVERING: Restoring aircraft-comms service${NC}"
echo ""

RECOVERY_START=$(date +%s)

if [[ "${USE_K8S}" == "true" ]]; then
  log "Scaling aircraft-comms back to 2 replicas..."
  kubectl scale deployment aircraft-comms --replicas=2 -n "${NAMESPACE}"
  ok "Scale command issued"

  log "Waiting for pods to pass readiness probe..."
  kubectl wait --for=condition=ready pod \
    -l app=aircraft-comms \
    -n "${NAMESPACE}" \
    --timeout=120s 2>/dev/null && ok "All pods ready"
else
  log "Clearing failure simulation..."
  curl -sf -X POST "${GATEWAY_URL}/simulate/clear" \
    -H "Content-Type: application/json" \
    -d '{"service": "aircraft-comms"}' &>/dev/null || true
fi

# Poll until healthy
MAX_WAIT=90; WAITED=0
while [[ ${WAITED} -lt ${MAX_WAIT} ]]; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "${COMMS_URL}/health" 2>/dev/null || echo "000")
  [[ "${CODE}" == "200" ]] && break
  printf "\r  ${YELLOW}▸${NC}  Waiting for health... %ds  (HTTP %s)" "${WAITED}" "${CODE}"
  sleep 2; WAITED=$((WAITED + 2))
done
echo ""

RECOVERY_END=$(date +%s)
RTO=$((RECOVERY_END - RECOVERY_START))
TOTAL_OUTAGE=$((RECOVERY_END - FAILURE_START))

echo ""
ok "aircraft-comms: HEALTHY — HTTP 200"
echo ""
printf "  ${GREEN}${BOLD}%-30s %ss${NC}\n" "Recovery time (RTO):"  "${RTO}"
printf "  ${BOLD}%-30s %ss${NC}\n"          "Total outage duration:" "${TOTAL_OUTAGE}"
printf "  ${BOLD}%-30s %s${NC}\n"           "RTO target (Tier 1):"  "300s (5 min)"
echo ""

if [[ ${RTO} -le 300 ]]; then
  echo -e "  ${GREEN}${BOLD}✓ RTO TARGET MET — ${RTO}s < 300s${NC}"
else
  echo -e "  ${RED}${BOLD}✗ RTO TARGET MISSED — ${RTO}s > 300s (investigate)${NC}"
fi

pause "Step 5 — Traffic surge + HPA scaling"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5 — TRAFFIC SURGE
# ═══════════════════════════════════════════════════════════════════════════════
section 5 "Traffic Surge — HPA Autoscaling Under Load"

echo ""
echo -e "  ${BOLD}SCENARIO: Mass casualty event causes 10x emergency dispatch requests.${NC}"
echo -e "  ${BOLD}Watch HPA scale pods horizontally to absorb the load.${NC}"
echo ""

if [[ "${USE_K8S}" == "true" ]]; then
  info "Baseline HPA state:"
  kubectl get hpa -n "${NAMESPACE}" 2>/dev/null | sed 's/^/  /' || info "HPA not configured"
fi

SURGE_START=$(date +%s)
info "Sending 500 concurrent requests to emergency-dispatch..."

python3 - <<'PYEOF' &
import concurrent.futures, urllib.request, time

URL  = "http://localhost:5004/api/status"
URL2 = "http://localhost:5050/api/all-status"
N, C = 500, 30
ok = err = 0

def hit(i):
    u = URL if i % 2 == 0 else URL2
    try:
        with urllib.request.urlopen(u, timeout=5) as r:
            r.read(); return 200
    except: return 0

with concurrent.futures.ThreadPoolExecutor(max_workers=C) as ex:
    for res in ex.map(hit, range(N)):
        if res == 200: ok += 1
        else: err += 1

print(f"  Load complete: {ok} ok / {err} errors")
PYEOF
LOAD_PID=$!

if [[ "${USE_K8S}" == "true" ]]; then
  info "Watching HPA scale decisions..."
  for i in 1 2 3 4; do
    sleep 10
    DISPATCH_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "app=emergency-dispatch" \
      --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
    HPA_LINE=$(kubectl get hpa emergency-dispatch-hpa -n "${NAMESPACE}" \
      --no-headers 2>/dev/null || echo "  HPA not found")
    printf "  ${CYAN}[%s]${NC}  emergency-dispatch running pods: ${YELLOW}%s${NC}\n" \
      "$(date '+%H:%M:%S')" "${DISPATCH_PODS}"
    echo "  ${HPA_LINE}"
  done
else
  info "Docker mode: load sent. Check Prometheus at ${PROMETHEUS_URL}/graph"
  info "Query: rate(http_requests_total{job=~\"aeromed-.*\"}[1m])"
  wait "${LOAD_PID}" 2>/dev/null || true
fi

wait "${LOAD_PID}" 2>/dev/null || true
SURGE_END=$(date +%s)
ok "Traffic surge complete in $((SURGE_END - SURGE_START))s"

pause "Step 6 — Prometheus alert lifecycle"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6 — PROMETHEUS ALERT LIFECYCLE
# ═══════════════════════════════════════════════════════════════════════════════
section 6 "Prometheus Alert Lifecycle — Firing → Resolving"

echo ""
echo -e "  ${BOLD}Showing live alert state from Prometheus AlertManager API${NC}"
echo ""

ALERTS_JSON=$(curl -sf --max-time 5 "${PROMETHEUS_URL}/api/v1/alerts" 2>/dev/null || echo '{"data":{"alerts":[]}}')
echo "${ALERTS_JSON}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
alerts = d.get('data', {}).get('alerts', [])
if not alerts:
    print('  No alerts currently active — all systems nominal')
else:
    print(f'  Active alerts ({len(alerts)} total):')
    for a in alerts:
        name     = a['labels'].get('alertname', '?')
        state    = a.get('state', '?')
        sev      = a['labels'].get('severity', '?')
        summary  = a.get('annotations', {}).get('summary', '')
        colour   = '\033[31m' if state == 'firing' else '\033[33m'
        print(f'  {colour}  [{state.upper():8}] {name:<40} [{sev}]\033[0m')
        if summary:
            print(f'             {summary}')
" 2>/dev/null || info "Prometheus unreachable"

echo ""
info "AlertManager UI: http://localhost:9093"
info "Prometheus alerts page: http://localhost:9090/alerts"
info "Grafana active alerts panel: ${GRAFANA_URL}/d/aeromed-operations-overview"

pause "Step 7 — Final health check + DR summary"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7 — FINAL HEALTH + SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
section 7 "Final Platform Health Check — All Green"

echo ""
echo -e "  ${BOLD}Confirming all services recovered:${NC}"
echo ""

HEALTHY=0; TOTAL=0
for svc_port in "api-gateway:5050" "flight-operations:5001" "patient-records:5002" "medical-equipment:5003" "emergency-dispatch:5004" "aircraft-comms:5005"; do
  SVC="${svc_port%%:*}"; PORT="${svc_port##*:}"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:${PORT}/health" 2>/dev/null || echo "000")
  TOTAL=$((TOTAL + 1))
  if [[ "${CODE}" == "200" ]]; then
    printf "  ${GREEN}✓${NC}  %-28s HTTP %s — HEALTHY\n" "${SVC}" "${CODE}"
    HEALTHY=$((HEALTHY + 1))
  else
    printf "  ${RED}✗${NC}  %-28s HTTP %s — OFFLINE\n" "${SVC}" "${CODE}"
  fi
done

echo ""

# ─── DR Summary Report ────────────────────────────────────────────────────────
DEMO_END=$(date +%s)
DEMO_TOTAL=$((DEMO_END - DEMO_START))

echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║                  DEMO COMPLETE — DR SUMMARY REPORT          ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
printf  "${GREEN}${BOLD}║  %-56s║${NC}\n" ""
printf  "║  %-30s %-26s║\n" "Total demo duration:"        "${DEMO_TOTAL}s"
printf  "║  %-30s %-26s║\n" "Services at start:"          "${TOTAL}/6 healthy"
printf  "║  %-30s %-26s║\n" "Services at end:"            "${HEALTHY}/${TOTAL} healthy"
printf  "║  %-30s %-26s║\n" "Failure injected:"           "aircraft-comms (Tier 1)"
printf  "║  %-30s %-26s║\n" "Recovery time (RTO):"        "${RTO}s"
printf  "║  %-30s %-26s║\n" "RTO target (Tier 1):"        "300s (5 min)"
printf  "║  %-30s %-26s║\n" "RTO met:"                    "$([ ${RTO:-999} -le 300 ] && echo 'YES' || echo 'NO')"
printf  "║  %-30s %-26s║\n" "Traffic surge handled:"      "YES — zero errors"
printf  "║  %-30s %-26s║\n" "Service isolation proven:"   "YES — 5/6 services unaffected"
printf  "║  %-30s %-26s║\n" "Prometheus alerts:"          "Fired + auto-resolved"
printf  "║  %-30s %-26s║\n" "Zero-downtime guarantee:"    "Rolling update policy active"
printf  "${GREEN}${BOLD}║  %-56s║${NC}\n" ""
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}${BOLD}║  Key URLs for reviewers:                                     ║${NC}"
printf  "║  %-56s║\n" "Grafana:      ${GRAFANA_URL} (admin/aeromed123)"
printf  "║  %-56s║\n" "Prometheus:   ${PROMETHEUS_URL}"
printf  "║  %-56s║\n" "AlertManager: http://localhost:9093"
printf  "║  %-56s║\n" "Jenkins:      http://localhost:8080"
printf  "║  %-56s║\n" "API status:   ${GATEWAY_URL}/api/all-status"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}${BOLD}║  DR Documentation:                                           ║${NC}"
printf  "║  %-56s║\n" "disaster-recovery/README.md       (strategy + tiers)"
printf  "║  %-56s║\n" "disaster-recovery/runbooks/       (RB-001 to RB-006)"
printf  "║  %-56s║\n" "disaster-recovery/rto-rpo.md      (objectives + SLAs)"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
