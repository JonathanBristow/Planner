#!/usr/bin/env bash
#
# dev-docker.sh — set up and run the local development environment with Docker.
#
# What it does (idempotent, safe to re-run):
#   1. Checks prerequisites (Docker, Compose v2, Node/Corepack) and free ports
#   2. Creates the .env files via ./setup.sh — only if they don't exist yet,
#      because setup.sh overwrites existing .env files
#   3. Builds the API image and starts Postgres, Valkey, RabbitMQ and MinIO
#   4. Runs database migrations
#   5. Starts the API, worker and beat-worker containers and waits for the API
#   6. Optionally starts the frontend apps (pnpm dev) on the host
#
# Usage: ./dev-docker.sh [command] [options]
#
# Commands:
#   up (default)   Set up and start the stack
#   down           Stop the stack (data volumes are kept)
#   reset          Stop the stack AND delete all data volumes (asks first)
#   logs           Follow container logs
#   status         Show container status
#
# Options:
#   --frontend     After the backend is up, run `pnpm dev` in the foreground
#   --no-build     Don't rebuild images
#   -y, --yes      Skip confirmation prompts
#   -h, --help     Show this help

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

COMPOSE_FILE="docker-compose-local.yml"
API_URL="http://localhost:8000"
INFRA_SERVICES=(plane-db plane-redis plane-mq plane-minio)
APP_SERVICES=(api worker beat-worker)
# host port -> what uses it
PORTS=("5432:Postgres" "6379:Valkey" "9000:MinIO" "9090:MinIO console" "8000:API")

if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'
  BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; BLUE=""; BOLD=""; NC=""
fi

info() { printf '%s==>%s %s\n' "$BLUE$BOLD" "$NC" "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%s✗%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

COMMAND="up"
FRONTEND=false
BUILD=true
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    up|down|reset|logs|status) COMMAND="$1" ;;
    --frontend)  FRONTEND=true ;;
    --no-build)  BUILD=false ;;
    -y|--yes)    ASSUME_YES=true ;;
    -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
  shift
done

check_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install Docker Desktop or Docker Engine first."
  docker info >/dev/null 2>&1 || die "Docker is installed but the daemon isn't running. Start Docker and retry."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required ('docker compose')."
  ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo ok), $(docker compose version --short 2>/dev/null)"
}

port_in_use() {
  local port=$1
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v nc >/dev/null 2>&1; then
    nc -z localhost "$port" >/dev/null 2>&1
  else
    return 1
  fi
}

check_ports() {
  # Ports already published by this project's own containers are fine.
  local running busy=()
  running=$(dc ps --services --status running 2>/dev/null || true)
  if [ -n "$running" ]; then
    ok "Stack already running; skipping port check"
    return
  fi
  local entry port name
  for entry in "${PORTS[@]}"; do
    port=${entry%%:*}; name=${entry#*:}
    if port_in_use "$port"; then busy+=("$port ($name)"); fi
  done
  if [ ${#busy[@]} -gt 0 ]; then
    die "Ports already in use: ${busy[*]}. Stop whatever is using them (e.g. a local Postgres) and retry."
  fi
  ok "Required ports are free"
}

check_node() {
  command -v node >/dev/null 2>&1 || die "Node.js not found. Install the version in .node-version (mise install, nvm, or nodejs.org)."
  command -v corepack >/dev/null 2>&1 || die "Corepack not found (ships with Node). Reinstall Node or run 'npm i -g corepack'."
  local want have
  want=$(tr -d 'v[:space:]' < .node-version 2>/dev/null || echo "")
  have=$(node -v | tr -d 'v')
  if [ -n "$want" ] && [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1)" != "$want" ]; then
    die "Node $have is older than the required $want."
  fi
  ok "Node $have"
}

setup_env() {
  local missing=false f
  for f in .env apps/api/.env apps/web/.env apps/admin/.env apps/space/.env apps/live/.env; do
    [ -f "$f" ] || missing=true
  done
  if [ "$missing" = false ]; then
    ok "Environment files already exist (leaving them untouched)"
    return
  fi
  if [ -f .env ] || [ -f apps/api/.env ]; then
    # setup.sh would regenerate secrets and overwrite files that exist.
    die "Some .env files exist and some don't. Fix this by hand (compare with the .env.example files), or delete all .env files and re-run."
  fi
  check_node
  info "Creating .env files and installing dependencies (setup.sh)"
  bash ./setup.sh
}

# Fail fast, with logs, if any given service isn't staying up (e.g. crash-looping).
assert_running() {
  local svc state
  for svc in "$@"; do
    state=$(dc ps --format '{{.State}}' "$svc" 2>/dev/null | head -n1)
    if [ "$state" != "running" ]; then
      warn "Service '$svc' is not running (state: ${state:-missing}). Last logs:"
      dc logs --tail=30 "$svc" >&2 || true
      if dc logs --tail=200 "$svc" 2>/dev/null | grep -q "Too short cookie string"; then
        warn "RabbitMQ's data volume is corrupt (empty Erlang cookie). Fix with:"
        warn "  docker compose -f $COMPOSE_FILE rm -sf plane-mq && docker volume rm \$(docker volume ls -q | grep rabbitmq_data) && ./dev-docker.sh"
      fi
      die "Aborting: '$svc' failed to start."
    fi
  done
}

wait_for_api() {
  info "Waiting for the API at $API_URL (first start runs instance setup and can take a minute)"
  local i
  for i in $(seq 1 90); do
    if [ $((i % 5)) -eq 0 ]; then assert_running "${INFRA_SERVICES[@]}" "${APP_SERVICES[@]}"; fi
    if curl -fsS -o /dev/null "$API_URL/" 2>/dev/null || [ "$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/" 2>/dev/null || true)" != "000" ]; then
      ok "API is responding"
      return 0
    fi
    sleep 2
  done
  warn "API didn't respond in time. Check: ./dev-docker.sh logs"
  return 1
}

cmd_up() {
  info "Checking prerequisites"
  check_docker
  check_ports
  setup_env

  local build_args=()
  [ "$BUILD" = true ] && build_args=(--build)

  info "Starting backing services (${INFRA_SERVICES[*]})"
  dc up -d "${INFRA_SERVICES[@]}"
  sleep 8
  assert_running "${INFRA_SERVICES[@]}"

  info "Running database migrations"
  if [ "$BUILD" = true ]; then dc build migrator; fi
  dc run --rm migrator

  info "Starting API and workers"
  dc up -d "${build_args[@]}" "${APP_SERVICES[@]}"

  wait_for_api || true

  echo
  ok "Backend is up"
  cat <<EOF

${BOLD}Services${NC}
  API            $API_URL
  MinIO console  http://localhost:9090   (credentials in .env)
  RabbitMQ       internal only (plane-mq)

${BOLD}Frontend${NC} (runs on the host, not in Docker)
  pnpm dev       web :3000 · admin :3001 · space :3002 · live :3100

${BOLD}First run${NC}
  Register as instance admin at http://localhost:3001/god-mode/,
  then sign in at http://localhost:3000 with the same credentials.

${BOLD}Manage${NC}
  ./dev-docker.sh logs | status | down | reset
EOF

  if [ "$FRONTEND" = true ]; then
    echo
    info "Starting frontend (Ctrl+C to stop; containers keep running)"
    check_node
    corepack enable pnpm
    [ -d node_modules ] || pnpm install
    exec pnpm dev
  fi
}

cmd_down() {
  check_docker
  info "Stopping containers (volumes kept)"
  dc down --remove-orphans
  ok "Stopped"
}

cmd_reset() {
  check_docker
  if [ "$ASSUME_YES" = false ]; then
    printf '%sThis deletes the Postgres, Valkey, RabbitMQ and MinIO volumes (all local data). Continue? [y/N] %s' "$YELLOW" "$NC"
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) die "Aborted." ;; esac
  fi
  dc down --volumes --remove-orphans
  ok "Containers and volumes removed. Run ./dev-docker.sh to start fresh."
}

case "$COMMAND" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  reset)  cmd_reset ;;
  logs)   check_docker; dc logs -f --tail=100 ;;
  status) check_docker; dc ps ;;
esac
