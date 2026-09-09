#!/bin/zsh

# ConnectSphere dev workflow manager
# Usage: ./dev.sh start | stop

# Derive the project root from this script's own location so it runs from any checkout.
PROJECT_DIR="${0:A:h}"
BACKEND_DIR="$PROJECT_DIR/backend"
XCODE_PROJECT="$PROJECT_DIR/ConnectSphere.xcodeproj"

OLLAMA_MODELS=("qwen2.5:7b-instruct-q4_k_m" "mxbai-embed-large")

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()  { echo "${BLUE}▶${NC} $1"; }
ok()   { echo "${GREEN}✓${NC} $1"; }
warn() { echo "${YELLOW}⚠${NC} $1"; }
err()  { echo "${RED}✗${NC} $1"; }

# ─────────────────────────────────────────
start() {
  echo ""
  echo "${BLUE}╔══════════════════════════════╗${NC}"
  echo "${BLUE}║   ConnectSphere — Starting   ║${NC}"
  echo "${BLUE}╚══════════════════════════════╝${NC}"
  echo ""

  # 1. Docker
  log "Starting Docker Desktop..."
  if docker info > /dev/null 2>&1; then
    ok "Docker already running"
  else
    open -a Docker
    echo "   Waiting for Docker daemon"
    while ! docker info > /dev/null 2>&1; do
      printf "."
      sleep 2
    done
    echo ""
    ok "Docker is ready"
  fi

  # 2. Ollama server (stays on the host — Docker can't use the GPU on macOS)
  log "Starting Ollama server..."
  if pgrep -x "ollama" > /dev/null; then
    ok "Ollama already running"
  else
    ollama serve > /tmp/ollama.log 2>&1 &
    sleep 2
    ok "Ollama server started (port 11434)"
  fi

  # 2b. Ensure the two models the AI pipeline needs are present
  for model in "${OLLAMA_MODELS[@]}"; do
    if ollama list 2>/dev/null | grep -q "${model%%:*}"; then
      ok "Ollama model present: $model"
    else
      log "Pulling Ollama model $model (first run only, this is large)..."
      ollama pull "$model" && ok "Pulled $model" || warn "Failed to pull $model — AI search will be degraded"
    fi
  done

  # 3. Docker services: PostgreSQL + Redis + the Swift/Vapor backend
  #    (first run builds the Swift release image — that is slow; later runs cache).
  log "Starting Docker services (Postgres, Redis, Swift backend)..."
  cd "$BACKEND_DIR"
  docker compose up -d --build > /dev/null 2>&1
  echo "   Waiting for the backend to be healthy (Swift build + boot migrations on first run)"
  while [ "$(docker compose ps backend --format '{{.Health}}' 2>/dev/null)" != "healthy" ]; do
    printf "."
    sleep 2
  done
  echo ""
  ok "Postgres, Redis, backend running"

  # 4. Migrations run automatically at boot (RUN_MIGRATIONS=1, advisory-locked,
  #    idempotent — see server/Sources/App/Infra/MigrationRunner.swift).
  ok "Migrations applied at boot"

  # 5. Xcode
  log "Opening Xcode..."
  open "$XCODE_PROJECT"
  ok "Xcode opened"

  # 6. VS Code
  log "Opening VS Code..."
  open -a "Visual Studio Code" "$PROJECT_DIR"
  ok "VS Code opened"

  # 7. TablePlus
  log "Opening TablePlus..."
  open -a TablePlus
  ok "TablePlus opened"

  # 8. Minimize everything except Xcode
  log "Minimizing background apps..."
  sleep 1
  osascript -e 'tell application "System Events" to set visible of process "Docker Desktop" to false' 2>/dev/null
  osascript -e 'tell application "System Events" to set visible of process "Code" to false' 2>/dev/null
  osascript -e 'tell application "System Events" to set visible of process "TablePlus" to false' 2>/dev/null
  ok "Docker Desktop, VS Code, TablePlus minimized (Xcode stays visible)"

  echo ""
  echo "${GREEN}╔══════════════════════════════╗${NC}"
  echo "${GREEN}║   All services are running   ║${NC}"
  echo "${GREEN}╚══════════════════════════════╝${NC}"
  echo ""
  echo "  Backend : http://localhost:3000  (container: connectsphere_backend)"
  echo "  Ollama  : http://localhost:11434 (host process)"
  echo "  Redis   : localhost:6379         (container: connectsphere_redis)"
  echo "  Logs    : cd backend && docker compose logs -f backend"
  echo ""
}

# ─────────────────────────────────────────
stop() {
  echo ""
  echo "${RED}╔══════════════════════════════╗${NC}"
  echo "${RED}║   ConnectSphere — Stopping   ║${NC}"
  echo "${RED}╚══════════════════════════════╝${NC}"
  echo ""

  # 1. iOS Simulator
  log "Closing iOS Simulator..."
  osascript -e 'tell application "Simulator" to quit' 2>/dev/null
  pkill -x "Simulator" 2>/dev/null && ok "Simulator closed" || warn "Simulator was not running"

  # 2. Xcode
  log "Closing Xcode..."
  osascript -e 'tell application "Xcode" to quit' 2>/dev/null && ok "Xcode closed" || warn "Xcode was not running"

  # 2b. VS Code
  log "Closing VS Code..."
  osascript -e 'tell application "Visual Studio Code" to quit' 2>/dev/null && ok "VS Code closed" || warn "VS Code was not running"

  # 2c. TablePlus
  log "Closing TablePlus..."
  osascript -e 'tell application "TablePlus" to quit' 2>/dev/null && ok "TablePlus closed" || warn "TablePlus was not running"

  # 3. Ollama (host process)
  log "Stopping Ollama..."
  if pkill -x "ollama" 2>/dev/null; then
    ok "Ollama stopped"
  else
    warn "Ollama was not running"
  fi

  # 4. Docker services: PostgreSQL + Redis + backend
  log "Stopping Docker services (Postgres, Redis, backend)..."
  cd "$BACKEND_DIR"
  docker compose down > /dev/null 2>&1 && ok "Docker services stopped" || warn "Docker services were not running"

  # 8. Docker Desktop — wait for containers to stop first
  log "Quitting Docker Desktop..."
  sleep 1
  osascript -e 'tell application "Docker Desktop" to quit' 2>/dev/null
  osascript -e 'tell application "Docker" to quit' 2>/dev/null
  sleep 2
  # Force-kill if still running
  pkill -x "Docker Desktop" 2>/dev/null
  ok "Docker Desktop closed"

  echo ""
  echo "${RED}╔══════════════════════════════╗${NC}"
  echo "${RED}║   All services stopped       ║${NC}"
  echo "${RED}╚══════════════════════════════╝${NC}"
  echo ""
}

# ─────────────────────────────────────────
case "$1" in
  start) start ;;
  stop)  stop  ;;
  *)
    echo "Usage: ./dev.sh [start|stop]"
    echo ""
    echo "  start  —  Docker + PostgreSQL + Redis + Ollama + Backend + Xcode + VS Code + TablePlus"
    echo "  stop   —  Dừng tất cả và đóng Xcode"
    ;;
esac
