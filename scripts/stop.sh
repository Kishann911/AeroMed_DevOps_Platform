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

echo ""
echo -e "${CYAN}${BOLD}AeroMed Platform — Graceful Shutdown${NC}"
echo ""

if ! docker info > /dev/null 2>&1; then
  echo -e "${RED}Docker is not running.${NC}"
  exit 1
fi

cd "$PROJECT_DIR"

echo -e "${YELLOW}Stopping all AeroMed containers gracefully...${NC}"
docker compose -f "$COMPOSE_FILE" stop --timeout 30

echo ""
echo -e "${YELLOW}Removing stopped containers...${NC}"
docker compose -f "$COMPOSE_FILE" rm -f

echo ""
echo -e "${GREEN}${BOLD}AeroMed Platform has been stopped.${NC}"
echo -e "  Named volumes (jenkins_home, grafana_storage, prometheus_data) are preserved."
echo -e "  Run ${BOLD}./scripts/start.sh${NC} to restart."
echo ""
