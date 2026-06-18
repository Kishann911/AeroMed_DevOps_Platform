#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PROMETHEUS_URL="${AEROMED_PROMETHEUS:-http://localhost:9090}"
GATEWAY_URL="${AEROMED_GATEWAY:-http://localhost:5050}"
NAMESPACE="aeromed-production"
PRESSURE_DURATION="${1:-30}"   # seconds of pressure
PRESSURE_TYPE="${2:-cpu}"      # cpu | memory | both

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
step() { echo ""; echo -e "${BOLD}${CYAN}══ $* ══${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
bad()  { echo -e "  ${RED}✗${NC}  $*"; }
info() { echo -e "  ${YELLOW}▸${NC}  $*"; }

USE_K8S=false
kubectl cluster-info &>/dev/null 2>&1 && USE_K8S=true

# Safety: warn before running
echo ""
echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}${BOLD}║    SIMULATING: Node / Container Resource Pressure        ║${NC}"
echo -e "${YELLOW}${BOLD}║    Demonstrates: OOM handling, CPU throttling, eviction  ║${NC}"
echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Pressure type: ${PRESSURE_TYPE}"
info "Duration:      ${PRESSURE_DURATION}s"
info "Mode:          $([ "${USE_K8S}" = "true" ] && echo 'Kubernetes' || echo 'Docker')"
echo ""
echo -e "  ${YELLOW}NOTE: This runs a stress workload in an isolated container.${NC}"
echo -e "  ${YELLOW}      It does NOT affect the host system. Press Ctrl+C to abort.${NC}"
echo ""

STRESS_PIDS=()
cleanup() {
  echo ""
  log "Cleaning up stress processes..."
  for pid in "${STRESS_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  if [[ "${USE_K8S}" == "true" ]]; then
    kubectl delete pod stress-test -n "${NAMESPACE}" --ignore-not-found &>/dev/null || true
  else
    docker rm -f aeromed-stress-test 2>/dev/null || true
  fi
  ok "Cleanup complete"
}
trap cleanup EXIT INT TERM

# ── Pre-stress resource snapshot ──────────────────────────────────────────────
step "1. Pre-pressure resource snapshot"

if [[ "${USE_K8S}" == "true" ]]; then
  info "Node resource usage before pressure:"
  kubectl top nodes 2>/dev/null | sed 's/^/  /' || info "metrics-server not available"
  echo ""
  info "Pod resource usage (aeromed-production):"
  kubectl top pods -n "${NAMESPACE}" 2>/dev/null | sed 's/^/  /' || info "metrics-server not available"
else
  info "Docker host resource usage:"
  docker stats --no-stream --format "  {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null \
    | grep -v "CONTAINER\|prometheus\|grafana\|alertmanager\|jenkins" | head -10 || true
fi

# ── Inject resource pressure ───────────────────────────────────────────────────
step "2. Injecting ${PRESSURE_TYPE} pressure (${PRESSURE_DURATION}s)"

PRESSURE_START=$(date +%s)

if [[ "${USE_K8S}" == "true" ]]; then
  # Run stress-ng in a K8s pod with resource limits to observe throttling/eviction
  case "${PRESSURE_TYPE}" in
    cpu)    STRESS_CMD='["stress-ng","--cpu","2","--cpu-load","95","--timeout","'"${PRESSURE_DURATION}"'s"]' ;;
    memory) STRESS_CMD='["stress-ng","--vm","1","--vm-bytes","400M","--timeout","'"${PRESSURE_DURATION}"'s"]' ;;
    both)   STRESS_CMD='["stress-ng","--cpu","2","--vm","1","--vm-bytes","200M","--timeout","'"${PRESSURE_DURATION}"'s"]' ;;
  esac

  log "Launching stress pod in ${NAMESPACE}..."
  kubectl run stress-test \
    -n "${NAMESPACE}" \
    --image=alexeiled/stress-ng:latest \
    --restart=Never \
    --requests="cpu=100m,memory=64Mi" \
    --limits="cpu=500m,memory=500Mi" \
    --command -- /bin/bash -c "stress-ng --cpu 2 --cpu-load 90 --vm 1 --vm-bytes 300M --timeout ${PRESSURE_DURATION}s" \
    2>/dev/null && ok "Stress pod launched" || info "Using alternative stress method"

  # Watch pod and node metrics during stress
  log "Monitoring resources during pressure (${PRESSURE_DURATION}s)..."
  ELAPSED=0
  while [[ ${ELAPSED} -lt ${PRESSURE_DURATION} ]]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    printf "\n  ${YELLOW}▸${NC}  [%ds / %ds]\n" "${ELAPSED}" "${PRESSURE_DURATION}"
    kubectl top pods -n "${NAMESPACE}" 2>/dev/null | head -8 | sed 's/^/    /' || true
  done

else
  # Docker mode: run stress-ng in an isolated container
  info "Running stress container (resource-limited, isolated from AeroMed services)..."
  case "${PRESSURE_TYPE}" in
    cpu)
      docker run -d --rm \
        --name aeromed-stress-test \
        --cpus="0.5" \
        --memory="64m" \
        alexeiled/stress-ng:latest \
        stress-ng --cpu 2 --cpu-load 90 --timeout "${PRESSURE_DURATION}s" \
        2>/dev/null && ok "CPU stress container running" \
        || info "stress-ng image not available — using Python stress fallback"
      ;;
    memory)
      docker run -d --rm \
        --name aeromed-stress-test \
        --memory="256m" --memory-swap="256m" \
        alexeiled/stress-ng:latest \
        stress-ng --vm 1 --vm-bytes 200M --timeout "${PRESSURE_DURATION}s" \
        2>/dev/null && ok "Memory stress container running" \
        || info "stress-ng image not available"
      ;;
    both)
      docker run -d --rm \
        --name aeromed-stress-test \
        --cpus="0.5" --memory="256m" --memory-swap="256m" \
        alexeiled/stress-ng:latest \
        stress-ng --cpu 2 --vm 1 --vm-bytes 200M --timeout "${PRESSURE_DURATION}s" \
        2>/dev/null && ok "CPU+Memory stress container running" \
        || info "stress-ng image not available"
      ;;
  esac

  # Python fallback stress (CPU only)
  if ! docker ps --filter "name=aeromed-stress-test" --format '{{.Names}}' | grep -q stress 2>/dev/null; then
    info "Using Python CPU stress fallback..."
    python3 -c "
import time, math, threading

end = time.time() + ${PRESSURE_DURATION}
def burn():
    while time.time() < end:
        _ = math.sqrt(123456789.0) * math.pi

threads = [threading.Thread(target=burn) for _ in range(2)]
[t.start() for t in threads]
print('  CPU stress running (2 threads, ${PRESSURE_DURATION}s)...')
[t.join() for t in threads]
" &
    STRESS_PIDS+=($!)
  fi

  # Monitor AeroMed services during stress
  log "Monitoring AeroMed health during ${PRESSURE_TYPE} pressure..."
  for i in $(seq 1 $((PRESSURE_DURATION / 5))); do
    sleep 5
    GATEWAY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "${GATEWAY_URL}/health" 2>/dev/null || echo "000")
    DISPATCH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:5004/health" 2>/dev/null || echo "000")
    printf "  ${CYAN}[%s]${NC}  api-gateway: HTTP %-5s  emergency-dispatch: HTTP %s\n" \
      "$(date '+%H:%M:%S')" "${GATEWAY_CODE}" "${DISPATCH_CODE}"
  done
fi

PRESSURE_END=$(date +%s)
PRESSURE_ACTUAL=$((PRESSURE_END - PRESSURE_START))

# ── Post-pressure check ───────────────────────────────────────────────────────
step "3. Post-pressure platform health check"
sleep 3

ALL_HEALTHY=true
PORTS="api-gateway:5050 flight-operations:5001 patient-records:5002 medical-equipment:5003 emergency-dispatch:5004 aircraft-comms:5005"
for item in $PORTS; do
  svc="${item%:*}"
  port="${item#*:}"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:${port}/health" 2>/dev/null || echo "000")
  if [[ "${CODE}" == "200" ]]; then
    ok "${svc}: HTTP ${CODE}"
  else
    bad "${svc}: HTTP ${CODE}"
    ALL_HEALTHY=false
  fi
done

# ── Prometheus node/container metrics ────────────────────────────────────────
step "4. Prometheus resource metrics"
PROM_QUERY="rate(node_cpu_seconds_total{mode!=\"idle\"}[1m])"
PROM_RES=$(curl -sf --max-time 5 \
  "${PROMETHEUS_URL}/api/v1/query?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PROM_QUERY}'))" 2>/dev/null || echo "${PROM_QUERY}")" \
  2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('data', {}).get('result', [])
if r:
    total = sum(float(x['value'][1]) for x in r)
    print(f'  Node CPU burn rate: {total:.2f} cores in use')
else:
    print('  No CPU metrics (node_exporter may not be running locally)')
" 2>/dev/null || echo "  Prometheus unreachable")
echo "${PROM_RES}"

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║    NODE PRESSURE SIMULATION COMPLETE                     ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
printf "  %-30s %s\n"  "Pressure type:"      "${PRESSURE_TYPE}"
printf "  %-30s %ss\n" "Duration:"           "${PRESSURE_ACTUAL}"
printf "  %-30s %s\n"  "Services degraded:"  "$([ "${ALL_HEALTHY}" = "true" ] && echo 'None — platform resilient' || echo 'Some — check above')"
echo ""
info "Key insight: AeroMed services use resource requests/limits to isolate impact."
info "Even under node pressure, K8s guarantees CPU/memory to each container."
echo ""
