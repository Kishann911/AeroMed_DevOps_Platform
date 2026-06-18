#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SERVICE_NAMES=( "api-gateway" "flight-operations" "patient-records" "medical-equipment" "emergency-dispatch" "aircraft-comms" )
SERVICE_PORTS=( "5050" "5001" "5002" "5003" "5004" "5005" )

INFRA_SERVICES=(
  "Prometheus|http://localhost:9090"
  "Grafana|http://localhost:3000   (admin/aeromed123)"
  "AlertManager|http://localhost:9093"
  "Jenkins|http://localhost:8080"
)

banner() {
  echo ""
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║       AeroMed DevOps Platform — Startup              ║${NC}"
  echo -e "${CYAN}${BOLD}║       Critical Care Air Ambulance Operations          ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
}

check_docker() {
  echo -e "${YELLOW}[1/4] Checking Docker...${NC}"
  if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Docker is not running. Please start Docker and try again.${NC}"
    exit 1
  fi
  echo -e "${GREEN}  Docker is running.${NC}"
}

start_stack() {
  echo ""
  echo -e "${YELLOW}[2/4] Starting all services...${NC}"
  cd "$PROJECT_DIR"
  docker compose -f "$COMPOSE_FILE" up -d --build
  echo -e "${GREEN}  docker compose up completed.${NC}"
}

wait_healthy() {
  echo ""
  echo -e "${YELLOW}[3/4] Waiting for AeroMed services to become healthy...${NC}"
  local max_wait=120
  local waited=0
  local interval=5

  while [ $waited -lt $max_wait ]; do
    local all_healthy=true
    for i in "${!SERVICE_NAMES[@]}"; do
      local svc="${SERVICE_NAMES[$i]}"
      local port="${SERVICE_PORTS[$i]}"
      if ! curl -sf "http://localhost:$port/health" > /dev/null 2>&1; then
        all_healthy=false
        break
      fi
    done
    if $all_healthy; then
      echo -e "${GREEN}  All services are healthy! (${waited}s)${NC}"
      return 0
    fi
    printf "  Waiting... %ds elapsed\r" $waited
    sleep $interval
    waited=$((waited + interval))
  done

  echo -e "${YELLOW}  Warning: Some services may not be healthy yet after ${max_wait}s.${NC}"
  echo -e "${YELLOW}  Run ./scripts/status.sh to check.${NC}"
}

print_status_table() {
  echo ""
  echo -e "${YELLOW}[4/4] Service Status Table${NC}"
  echo ""
  printf "  %-28s %-10s %-40s\n" "SERVICE" "STATUS" "URL"
  printf "  %-28s %-10s %-40s\n" "-------" "------" "---"

  for i in "${!SERVICE_NAMES[@]}"; do
    local svc="${SERVICE_NAMES[$i]}"
    local port="${SERVICE_PORTS[$i]}"
    local url="http://localhost:$port"
    local status
    if curl -sf "$url/health" > /dev/null 2>&1; then
      status="${GREEN}HEALTHY${NC}"
    else
      status="${RED}OFFLINE${NC}"
    fi
    printf "  %-28s " "$svc"
    printf "${status}"
    printf "%-10s" ""
    printf "  %-40s\n" "$url"
  done

  echo ""
  echo -e "  ${BOLD}Infrastructure:${NC}"
  for entry in "${INFRA_SERVICES[@]}"; do
    local name="${entry%%|*}"
    local url="${entry##*|}"
    printf "  %-28s %s\n" "$name" "$url"
  done

  echo ""
  echo -e "  ${BOLD}API Gateway Endpoints:${NC}"
  echo "  http://localhost:5050/api/all-status   (aggregated health)"
  echo "  http://localhost:5050/api/status       (gateway status)"
  echo "  POST http://localhost:5050/simulate/failure"
  echo ""
}

main() {
  banner
  check_docker
  start_stack
  wait_healthy
  print_status_table
  echo -e "${GREEN}${BOLD}  ✓ AeroMed Platform is LIVE${NC}"
  echo ""
}

main
