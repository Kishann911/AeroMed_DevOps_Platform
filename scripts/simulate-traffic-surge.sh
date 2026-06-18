#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

GATEWAY_URL="${AEROMED_GATEWAY:-http://localhost:5000}"
DISPATCH_URL="${AEROMED_DISPATCH:-http://localhost:5004}"
PROMETHEUS_URL="${AEROMED_PROMETHEUS:-http://localhost:9090}"
NAMESPACE="aeromed-production"
SURGE_DURATION="${1:-60}"     # seconds of load
TOTAL_REQUESTS="${2:-1000}"   # total requests to send
CONCURRENCY="${3:-50}"        # concurrent workers

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
step() { echo ""; echo -e "${BOLD}${CYAN}══ $* ══${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
info() { echo -e "  ${YELLOW}▸${NC}  $*"; }

USE_K8S=false
kubectl cluster-info &>/dev/null 2>&1 && USE_K8S=true

echo ""
echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}${BOLD}║    SIMULATING: Mass Casualty Traffic Surge               ║${NC}"
echo -e "${YELLOW}${BOLD}║    Scenario: Emergency event floods all services         ║${NC}"
echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Target:       ${DISPATCH_URL}/api/status  (+  ${GATEWAY_URL}/api/all-status)"
info "Requests:     ${TOTAL_REQUESTS} total, ${CONCURRENCY} concurrent"
info "Duration:     ${SURGE_DURATION}s"
info "Mode:         $([ "${USE_K8S}" = "true" ] && echo 'Kubernetes (watching HPA)' || echo 'Docker Compose')"

# ── Baseline replica count ────────────────────────────────────────────────────
step "1. Baseline replica count before surge"
if [[ "${USE_K8S}" == "true" ]]; then
  kubectl get hpa -n "${NAMESPACE}" 2>/dev/null \
    | head -10 \
    || info "HPA not found — ensure metrics-server is running"
  BASELINE_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "app=emergency-dispatch" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  info "emergency-dispatch baseline pods: ${BASELINE_PODS}"
else
  info "Docker Compose mode — no HPA; container auto-restart applies"
  BASELINE_PODS=1
fi

# ── Choose load generator ─────────────────────────────────────────────────────
step "2. Starting traffic surge (${TOTAL_REQUESTS} req @ ${CONCURRENCY} concurrent)"

SURGE_START=$(date +%s)

if command -v ab &>/dev/null; then
  info "Using Apache Bench (ab) for load generation..."
  echo ""
  # Spread load across gateway (which fans out to all services)
  ab -n "${TOTAL_REQUESTS}" -c "${CONCURRENCY}" -q \
    "${GATEWAY_URL}/api/all-status" 2>&1 \
    | grep -E "Requests per second|Time per request|Failed requests|Complete requests" \
    | sed 's/^/  /'
  AB_EXIT=$?
elif command -v python3 &>/dev/null; then
  info "Using Python concurrent.futures for load generation..."
  echo ""
  python3 - <<PYEOF
import concurrent.futures, urllib.request, time, sys

URL   = "${DISPATCH_URL}/api/status"
URL2  = "${GATEWAY_URL}/api/all-status"
N     = int("${TOTAL_REQUESTS}")
C     = int("${CONCURRENCY}")
DUR   = int("${SURGE_DURATION}")

results = {"ok": 0, "err": 0, "total_ms": 0.0}
deadline = time.time() + DUR

def hit(url):
    t0 = time.time()
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            r.read()
            return (r.status, (time.time()-t0)*1000)
    except Exception as e:
        return (0, (time.time()-t0)*1000)

urls = [URL if i % 2 == 0 else URL2 for i in range(N)]
sent = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=C) as ex:
    futs = {ex.submit(hit, u): u for u in urls}
    for fut in concurrent.futures.as_completed(futs):
        code, ms = fut.result()
        if code == 200:
            results["ok"] += 1
        else:
            results["err"] += 1
        results["total_ms"] += ms
        sent += 1
        if sent % 100 == 0:
            elapsed = time.time() - (deadline - DUR)
            rps = sent / elapsed if elapsed > 0 else 0
            print(f"  \033[33m▸\033[0m  {sent}/{N} requests — {rps:.0f} req/s — {results['err']} errors", flush=True)

total = results["ok"] + results["err"]
avg_ms = results["total_ms"] / total if total else 0
rps    = total / DUR

print(f"""
  \033[32m✓\033[0m  Load complete
     Total requests:  {total}
     Successful:      {results['ok']} ({100*results['ok']//total if total else 0}%)
     Errors:          {results['err']}
     Avg response:    {avg_ms:.1f}ms
     Req/s:           {rps:.1f}
""")
PYEOF
else
  info "Neither 'ab' nor python3 found. Using curl loop..."
  for i in $(seq 1 20); do
    curl -sf "${GATEWAY_URL}/api/all-status" &>/dev/null &
  done
  wait
  ok "Sent 20 parallel curl requests"
fi

SURGE_END=$(date +%s)
SURGE_ACTUAL=$((SURGE_END - SURGE_START))

# ── HPA scaling observation ───────────────────────────────────────────────────
step "3. Observing HPA / pod scaling"
if [[ "${USE_K8S}" == "true" ]]; then
  log "Current HPA state:"
  kubectl get hpa -n "${NAMESPACE}" 2>/dev/null | sed 's/^/  /'

  log "Polling pod counts every 5s for 30s..."
  for i in 1 2 3 4 5 6; do
    DISPATCH_PODS=$(kubectl get pods -n "${NAMESPACE}" \
      -l "app=emergency-dispatch" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ALL_PODS=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    printf "  %s  %ds  emergency-dispatch pods: ${YELLOW}%s${NC}  total pods: %s\n" \
      "$(date '+%H:%M:%S')" "$((i*5))" "${DISPATCH_PODS}" "${ALL_PODS}"
    sleep 5
  done

  PEAK_PODS=$(kubectl get pods -n "${NAMESPACE}" -l "app=emergency-dispatch" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ok "HPA scaled emergency-dispatch: ${BASELINE_PODS} → ${PEAK_PODS} replicas under load"
else
  info "Docker Compose: no HPA. Check Prometheus request-rate graph at http://localhost:9090"
  info "Grafana request rate dashboard: http://localhost:3000/d/aeromed-operations-overview"
fi

# ── Check Prometheus request rate metric ─────────────────────────────────────
step "4. Prometheus metrics snapshot"
RPS_JSON=$(curl -sf --max-time 5 \
  "${PROMETHEUS_URL}/api/v1/query?query=rate(http_requests_total%7Bjob%3D~%22aeromed-.*%22%7D%5B1m%5D)" \
  2>/dev/null || echo '{}')
echo "${RPS_JSON}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('data', {}).get('result', [])
if not results:
    print('  \033[33m▸\033[0m  No metrics yet (scrape interval)')
else:
    print('  Current request rates:')
    for r in results:
        job = r.get('labels', {}).get('job', 'unknown')
        val = float(r.get('value', [0,0])[1])
        print(f'    {job:<35} {val:.2f} req/s')
" 2>/dev/null || info "Prometheus unreachable"

# ── Scale-down observation ────────────────────────────────────────────────────
if [[ "${USE_K8S}" == "true" ]]; then
  step "5. Watching pods scale back down (stabilization window: ~60s)"
  info "Kubernetes HPA stabilizationWindowSeconds prevents immediate scale-down"
  info "Watching for 60s..."
  for i in 1 2 3 4; do
    sleep 15
    CURRENT=$(kubectl get pods -n "${NAMESPACE}" -l "app=emergency-dispatch" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')
    printf "  ${CYAN}[%s]${NC}  emergency-dispatch replicas: ${YELLOW}%s${NC}\n" \
      "$(date '+%H:%M:%S')" "${CURRENT}"
  done
fi

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║    TRAFFIC SURGE SIMULATION COMPLETE                     ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
printf "  %-30s %ss\n"  "Surge duration:"   "${SURGE_ACTUAL}"
printf "  %-30s %s\n"   "Requests sent:"    "${TOTAL_REQUESTS}"
printf "  %-30s %s\n"   "Concurrency:"      "${CONCURRENCY}"
if [[ "${USE_K8S}" == "true" ]]; then
  printf "  %-30s %s → %s\n" "Replica range:" "${BASELINE_PODS}" "${PEAK_PODS:-?}"
fi
echo ""
info "View real-time graphs: http://localhost:3000/d/aeromed-operations-overview"
echo ""
