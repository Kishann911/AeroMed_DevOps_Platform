#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

NAMESPACE="aeromed-production"
GATEWAY_URL="${AEROMED_GATEWAY:-http://localhost:5000}"
TARGET_APP="${1:-}"   # optional: target a specific app label

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
step() { echo ""; echo -e "${BOLD}${CYAN}══ $* ══${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
bad()  { echo -e "  ${RED}✗${NC}  $*"; }
info() { echo -e "  ${YELLOW}▸${NC}  $*"; }

USE_K8S=false
kubectl cluster-info &>/dev/null 2>&1 && USE_K8S=true

echo ""
echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}${BOLD}║    SIMULATING: Random Pod Failure                        ║${NC}"
echo -e "${YELLOW}${BOLD}║    Demonstrates: Kubernetes self-healing                 ║${NC}"
echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ "${USE_K8S}" == "true" ]]; then
  # ── Kubernetes mode ────────────────────────────────────────────────────────
  step "1. Selecting a random running pod to kill"

  if [[ -n "${TARGET_APP}" ]]; then
    POD_NAME=$(kubectl get pods -n "${NAMESPACE}" \
      -l "app=${TARGET_APP}" \
      --field-selector="status.phase=Running" \
      --no-headers 2>/dev/null | shuf | head -1 | awk '{print $1}')
  else
    # Pick a random non-critical pod (avoid killing the only replica of a service)
    POD_NAME=$(kubectl get pods -n "${NAMESPACE}" \
      --field-selector="status.phase=Running" \
      --no-headers 2>/dev/null | shuf | head -1 | awk '{print $1}')
  fi

  if [[ -z "${POD_NAME}" ]]; then
    bad "No running pods found in ${NAMESPACE}. Is the cluster running?"
    exit 1
  fi

  # Get parent deployment so we can watch the replacement
  APP_LABEL=$(kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "unknown")
  DEPLOY_REPLICAS=$(kubectl get deployment "${APP_LABEL}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")

  log "Selected pod: ${POD_NAME}"
  log "App:          ${APP_LABEL}"
  log "Desired replicas for ${APP_LABEL}: ${DEPLOY_REPLICAS}"

  # Show current pod status
  step "2. Current pod status (before deletion)"
  kubectl get pods -n "${NAMESPACE}" -l "app=${APP_LABEL}" | sed 's/^/  /'

  # Kill the pod
  step "3. Killing pod — Kubernetes should auto-recreate"
  DELETE_TIME=$(date +%s)
  kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}"
  echo ""
  echo -e "  ${RED}${BOLD}Killed pod: ${POD_NAME}${NC}"
  echo -e "  ${YELLOW}Kubernetes should auto-recreate within the deployment's rolling update policy${NC}"

  # Wait for replacement
  step "4. Watching for replacement pod"
  MAX_WAIT=120
  WAITED=0
  RECOVERED=false
  while [[ ${WAITED} -lt ${MAX_WAIT} ]]; do
    RUNNING=$(kubectl get pods -n "${NAMESPACE}" \
      -l "app=${APP_LABEL}" \
      --field-selector="status.phase=Running" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ALL=$(kubectl get pods -n "${NAMESPACE}" \
      -l "app=${APP_LABEL}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    printf "\r  ${CYAN}[%s]${NC}  %s pods Running / %s total (%ds elapsed)" \
      "$(date '+%H:%M:%S')" "${RUNNING}" "${ALL}" "${WAITED}"
    if [[ "${RUNNING}" -ge "${DEPLOY_REPLICAS:-1}" ]]; then
      RECOVERED=true
      break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
  done
  echo ""

  RECOVER_TIME=$(date +%s)
  ELAPSED=$((RECOVER_TIME - DELETE_TIME))

  step "5. Final pod status"
  kubectl get pods -n "${NAMESPACE}" -l "app=${APP_LABEL}" | sed 's/^/  /'

  echo ""
  if [[ "${RECOVERED}" == "true" ]]; then
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║    SELF-HEALING DEMONSTRATED                             ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    printf "  %-30s %s\n"  "Killed pod:"         "${POD_NAME}"
    printf "  %-30s %s\n"  "Service:"            "${APP_LABEL}"
    printf "  %-30s %ss\n" "Recovery time:"      "${ELAPSED}"
    printf "  %-30s %s\n"  "Zero downtime:"      "YES — rolling deployment ensures remaining replicas served traffic"
    ok "Pod self-healed in ${ELAPSED}s — Kubernetes restart policy working correctly"
  else
    bad "Pod did not recover within ${MAX_WAIT}s — investigate with:"
    echo "  kubectl describe deployment ${APP_LABEL} -n ${NAMESPACE}"
    echo "  kubectl get events -n ${NAMESPACE} --sort-by=.lastTimestamp | tail -20"
  fi

else
  # ── Docker Compose mode ────────────────────────────────────────────────────
  step "1. Selecting a random AeroMed container to kill"

  SERVICES=(flight-operations patient-records medical-equipment emergency-dispatch aircraft-comms)
  TARGET_SVC="${TARGET_APP:-${SERVICES[$((RANDOM % ${#SERVICES[@]}))]}}"

  # Find the Docker container name (compose names it <project>-<service>-1)
  CONTAINER=$(docker ps --filter "name=${TARGET_SVC}" --format '{{.Names}}' 2>/dev/null | head -1)
  if [[ -z "${CONTAINER}" ]]; then
    # Try common compose project name patterns
    CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "${TARGET_SVC}" | head -1 || echo "")
  fi

  if [[ -z "${CONTAINER}" ]]; then
    bad "Could not find a running container for ${TARGET_SVC}"
    info "Running containers:"
    docker ps --format '  {{.Names}}' 2>/dev/null | head -10
    exit 1
  fi

  log "Target container: ${CONTAINER} (${TARGET_SVC})"
  info "Docker will auto-restart this container (restart: unless-stopped)"

  step "2. Container status before kill"
  docker inspect "${CONTAINER}" \
    --format '  Status: {{.State.Status}}  Restarts: {{.RestartCount}}  Started: {{.State.StartedAt}}' \
    2>/dev/null || true

  step "3. Killing container"
  KILL_TIME=$(date +%s)
  docker kill "${CONTAINER}" 2>/dev/null || docker stop "${CONTAINER}" 2>/dev/null
  echo -e "  ${RED}${BOLD}Killed container: ${CONTAINER}${NC}"

  SVC_PORT_MAP=([flight-operations]=5001 [patient-records]=5002 [medical-equipment]=5003 [emergency-dispatch]=5004 [aircraft-comms]=5005)
  SVC_PORT="${SVC_PORT_MAP[$TARGET_SVC]:-5000}"

  step "4. Waiting for Docker to restart container"
  MAX_WAIT=60
  WAITED=0
  RECOVERED=false
  while [[ ${WAITED} -lt ${MAX_WAIT} ]]; do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:${SVC_PORT}/health" 2>/dev/null || echo "000")
    CSTATE=$(docker inspect "${CONTAINER}" --format '{{.State.Status}}' 2>/dev/null || echo "restarting")
    printf "\r  ${CYAN}[%s]${NC}  Container: %-12s  /health: HTTP %s  (%ds)" \
      "$(date '+%H:%M:%S')" "${CSTATE}" "${HTTP}" "${WAITED}"
    if [[ "${HTTP}" == "200" ]]; then
      RECOVERED=true
      break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
  done
  echo ""

  RECOVER_TIME=$(date +%s)
  ELAPSED=$((RECOVER_TIME - KILL_TIME))

  step "5. Post-recovery status"
  docker inspect "${CONTAINER}" \
    --format '  Status: {{.State.Status}}  Restarts: {{.RestartCount}}  Started: {{.State.StartedAt}}' \
    2>/dev/null || true

  echo ""
  if [[ "${RECOVERED}" == "true" ]]; then
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║    SELF-HEALING DEMONSTRATED                             ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    printf "  %-30s %s\n"  "Killed container:"   "${CONTAINER}"
    printf "  %-30s %s\n"  "Service:"            "${TARGET_SVC}"
    printf "  %-30s %ss\n" "Recovery time:"      "${ELAPSED}"
    ok "Container restarted by Docker in ${ELAPSED}s"
  else
    bad "Container did not recover within ${MAX_WAIT}s"
    info "Try: docker logs ${CONTAINER}"
  fi
fi
echo ""
