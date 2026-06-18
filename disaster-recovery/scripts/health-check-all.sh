#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="aeromed-production"
TIMEOUT="${HEALTH_CHECK_TIMEOUT:-5}"

# ANSI colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
WARN=0

ok()   { echo -e "  ${GREEN}[  OK  ]${RESET}  $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[ FAIL ]${RESET}  $*"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}[ WARN ]${RESET}  $*"; WARN=$((WARN + 1)); }

check_http() {
  local name="$1"
  local url="$2"
  local expected_status="${3:-200}"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" "${url}" 2>/dev/null || echo "000")
  if [[ "${status}" == "${expected_status}" ]]; then
    ok "${name} — HTTP ${status}"
  else
    fail "${name} — HTTP ${status} (expected ${expected_status}) @ ${url}"
  fi
}

check_pod() {
  local label="$1"
  local display="$2"
  local count
  count=$(kubectl get pods -n "${NAMESPACE}" -l "app=${label}" --field-selector="status.phase=Running" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  local desired
  desired=$(kubectl get deployment -n "${NAMESPACE}" "${label}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  if [[ "${count}" -gt 0 ]]; then
    ok "${display} — ${count}/${desired} pods Running"
  else
    fail "${display} — 0/${desired} pods Running"
  fi
}

echo ""
echo -e "${BOLD}================================================================${RESET}"
echo -e "${BOLD}       AeroMed Platform Health Check                          ${RESET}"
echo -e "${BOLD}       $(date -u +'%Y-%m-%d %H:%M:%S UTC')                   ${RESET}"
echo -e "${BOLD}================================================================${RESET}"

# ── Section 1: Service /health Endpoints ─────────────────────────────────────
echo ""
echo -e "${BOLD}[1/4] Service Health Endpoints${RESET}"

# Resolve service endpoints — use kubectl port-forward in a real env,
# or use the in-cluster service DNS if running inside the cluster.
# For out-of-cluster checks we detect the ingress IP.
INGRESS_HOST=$(kubectl get ingress -n "${NAMESPACE}" aeromed-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null \
  || kubectl get ingress -n "${NAMESPACE}" aeromed-ingress \
     -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null \
  || echo "localhost")

check_http "api-gateway         (port 5000)" "http://${INGRESS_HOST}/api-gateway/health"
check_http "flight-operations   (port 5001)" "http://${INGRESS_HOST}/flight-operations/health"
check_http "patient-records     (port 5002)" "http://${INGRESS_HOST}/patient-records/health"
check_http "medical-equipment   (port 5003)" "http://${INGRESS_HOST}/medical-equipment/health"
check_http "emergency-dispatch  (port 5004)" "http://${INGRESS_HOST}/emergency-dispatch/health"
check_http "aircraft-comms      (port 5005)" "http://${INGRESS_HOST}/aircraft-comms/health"

# ── Section 2: Kubernetes Pod Status ─────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/4] Kubernetes Pod Status${RESET}"

for svc in api-gateway flight-operations patient-records medical-equipment emergency-dispatch aircraft-comms; do
  check_pod "${svc}" "${svc}"
done

# Check for CrashLoopBackOff
CRASHLOOP=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
  | grep CrashLoopBackOff | awk '{print $1}' | tr '\n' ' ')
if [[ -n "${CRASHLOOP}" ]]; then
  fail "CrashLoopBackOff pods detected: ${CRASHLOOP}"
else
  ok "No CrashLoopBackOff pods"
fi

# ── Section 3: Monitoring Stack ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/4] Monitoring Stack${RESET}"

PROMETHEUS_HOST=$(kubectl get service -n monitoring prometheus -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "prometheus.monitoring.svc.cluster.local")
GRAFANA_HOST=$(kubectl get service -n monitoring grafana -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "grafana.monitoring.svc.cluster.local")
ALERTMANAGER_HOST=$(kubectl get service -n monitoring alertmanager -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "alertmanager.monitoring.svc.cluster.local")

check_http "Prometheus         " "http://${PROMETHEUS_HOST}:9090/-/healthy"
check_http "Grafana            " "http://${GRAFANA_HOST}:3000/api/health"
check_http "AlertManager       " "http://${ALERTMANAGER_HOST}:9093/-/healthy"

# Check Prometheus is actively scraping AeroMed targets
PROM_TARGETS=$(curl -s "http://${PROMETHEUS_HOST}:9090/api/v1/targets" 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for t in d['data']['activeTargets'] if 'aeromed' in t.get('labels',{}).get('job','') and t['health']=='up'))" \
  2>/dev/null || echo "0")
if [[ "${PROM_TARGETS}" -ge 6 ]]; then
  ok "Prometheus scraping AeroMed targets — ${PROM_TARGETS} up"
elif [[ "${PROM_TARGETS}" -gt 0 ]]; then
  warn "Prometheus scraping — only ${PROM_TARGETS}/6 AeroMed targets up"
else
  fail "Prometheus not scraping any AeroMed targets"
fi

# ── Section 4: Critical Business Metrics ─────────────────────────────────────
echo ""
echo -e "${BOLD}[4/4] Critical Business Metrics${RESET}"

query_prometheus() {
  local query="$1"
  curl -sg "http://${PROMETHEUS_HOST}:9090/api/v1/query?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))" 2>/dev/null || echo "$query")" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['result'][0]['value'][1] if d['data']['result'] else 'N/A')" \
    2>/dev/null || echo "N/A"
}

HEALTHY_SERVICES=$(query_prometheus 'count(up{job=~"aeromed-.*"} == 1)')
ACTIVE_EMERGENCIES=$(query_prometheus 'aeromed_emergency_dispatch_active_count')
ACTIVE_FLIGHTS=$(query_prometheus 'aeromed_flights_active_count')

if [[ "${HEALTHY_SERVICES}" == "6" ]]; then
  ok "Healthy services: ${HEALTHY_SERVICES}/6"
elif [[ "${HEALTHY_SERVICES}" != "N/A" && "${HEALTHY_SERVICES}" -ge 4 ]]; then
  warn "Healthy services: ${HEALTHY_SERVICES}/6 — degraded"
else
  fail "Healthy services: ${HEALTHY_SERVICES}/6 — critical"
fi

echo -e "  ${BOLD}Active emergencies:${RESET} ${ACTIVE_EMERGENCIES}"
echo -e "  ${BOLD}Active flights:${RESET}    ${ACTIVE_FLIGHTS}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}================================================================${RESET}"
TOTAL=$((PASS + FAIL + WARN))
echo -e "  Total checks: ${TOTAL} | ${GREEN}OK: ${PASS}${RESET} | ${YELLOW}WARN: ${WARN}${RESET} | ${RED}FAIL: ${FAIL}${RESET}"

# Tier 1 services: flight-operations, emergency-dispatch, aircraft-comms
TIER1_FAIL=0
for svc in flight-operations emergency-dispatch aircraft-comms; do
  COUNT=$(kubectl get pods -n "${NAMESPACE}" -l "app=${svc}" --field-selector="status.phase=Running" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "${COUNT}" -eq 0 ]] && TIER1_FAIL=$((TIER1_FAIL + 1))
done

echo ""
if [[ "${FAIL}" -eq 0 && "${TIER1_FAIL}" -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}STATUS: ALL SYSTEMS HEALTHY${RESET}"
  echo -e "${BOLD}================================================================${RESET}"
  echo ""
  exit 0
elif [[ "${TIER1_FAIL}" -gt 0 ]]; then
  echo -e "  ${RED}${BOLD}STATUS: CRITICAL — ${TIER1_FAIL} TIER 1 SERVICE(S) DOWN${RESET}"
  echo -e "  ${RED}Activate RB-001 or RB-005 immediately.${RESET}"
  echo -e "${BOLD}================================================================${RESET}"
  echo ""
  exit 1
else
  echo -e "  ${YELLOW}${BOLD}STATUS: DEGRADED — ${FAIL} check(s) failed${RESET}"
  echo -e "${BOLD}================================================================${RESET}"
  echo ""
  exit 1
fi
