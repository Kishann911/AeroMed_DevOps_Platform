#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

get_aeromed_port() {
  case "$1" in
    api-gateway) echo "5050" ;;
    flight-operations) echo "5001" ;;
    patient-records) echo "5002" ;;
    medical-equipment) echo "5003" ;;
    emergency-dispatch) echo "5004" ;;
    aircraft-comms) echo "5005" ;;
  esac
}

get_infra_port() {
  case "$1" in
    prometheus) echo "9090" ;;
    grafana) echo "3000" ;;
    alertmanager) echo "9093" ;;
    jenkins) echo "8080" ;;
  esac
}

check_endpoint() {
  local url="$1"
  if curl -sf --max-time 3 "$url" > /dev/null 2>&1; then
    echo "UP"
  else
    echo "DOWN"
  fi
}

get_health_json() {
  local url="$1"
  curl -sf --max-time 3 "$url" 2>/dev/null || echo "{}"
}

print_row() {
  local name="$1"
  local status="$2"
  local url="$3"
  local extra="${4:-}"
  if [ "$status" = "UP" ]; then
    printf "  %-28s ${GREEN}%-8s${NC}  %-36s %s\n" "$name" "HEALTHY" "$url" "$extra"
  else
    printf "  %-28s ${RED}%-8s${NC}  %-36s %s\n" "$name" "OFFLINE" "$url" "$extra"
  fi
}

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║       AeroMed Platform — Health Status               ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Checked at: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

printf "  %-28s %-8s  %-36s %s\n" "SERVICE" "STATUS" "URL" "VERSION"
printf "  %-28s %-8s  %-36s %s\n" "-------" "------" "---" "-------"

healthy_count=0
total_count=0

for svc in api-gateway flight-operations patient-records medical-equipment emergency-dispatch aircraft-comms; do
  port="$(get_aeromed_port "$svc")"
  url="http://localhost:$port"
  status=$(check_endpoint "$url/health")
  total_count=$((total_count + 1))
  version=""
  if [ "$status" = "UP" ]; then
    healthy_count=$((healthy_count + 1))
    version=$(get_health_json "$url/health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('version',''))" 2>/dev/null || echo "")
  fi
  print_row "$svc" "$status" "$url" "$version"
done

echo ""
echo -e "  ${BOLD}Infrastructure:${NC}"
printf "  %-28s %-8s  %-36s\n" "SERVICE" "STATUS" "URL"
printf "  %-28s %-8s  %-36s\n" "-------" "------" "---"

for svc in prometheus grafana alertmanager jenkins; do
  port="$(get_infra_port "$svc")"
  url="http://localhost:$port"
  status=$(check_endpoint "$url")
  print_row "$svc" "$status" "$url"
done

echo ""
if [ "$healthy_count" -eq "$total_count" ]; then
  echo -e "  ${GREEN}${BOLD}Overall: ALL $total_count AeroMed services are HEALTHY${NC}"
elif [ "$healthy_count" -eq 0 ]; then
  echo -e "  ${RED}${BOLD}Overall: ALL services are OFFLINE — is the stack running?${NC}"
  echo -e "  Run ${BOLD}./scripts/start.sh${NC} to start the platform."
else
  echo -e "  ${YELLOW}${BOLD}Overall: $healthy_count/$total_count AeroMed services are healthy${NC}"
fi
echo ""
