#!/bin/zsh

# ConnectSphere dev workflow manager
# Usage: ./dev.sh start | stop

# Derive the project root from this script's own location so it runs from any checkout.
PROJECT_DIR="${0:A:h}"
BACKEND_DIR="$PROJECT_DIR/backend"   # infra dir: docker-compose.yml, .env, migrations/, uploads/
SERVER_DIR="$PROJECT_DIR/server"     # the Swift/Vapor backend (runs on the host)
XCODE_PROJECT="$PROJECT_DIR/ConnectSphere.xcodeproj"
SERVER_LOG="/tmp/connectsphere-server.log"

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
  echo "${BLUE}║   ConnectSphere, Starting   ║${NC}"
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

  # 2. Ollama server (stays on the host, Docker can't use the GPU on macOS)
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
      ollama pull "$model" && ok "Pulled $model" || warn "Failed to pull $model, AI search will be degraded"
    fi
  done

  # 3. Docker: the data layer ONLY, Postgres 16 + pgvector and Redis.
  #    The Swift backend runs on the host (step 3b), not as a container.
  log "Starting Docker data layer (Postgres, Redis)..."
  cd "$BACKEND_DIR"
  docker compose up -d postgres redis > /dev/null 2>&1
  echo "   Waiting for Postgres + Redis to be healthy"
  for svc in postgres redis; do
    while [ "$(docker compose ps "$svc" --format '{{.Health}}' 2>/dev/null)" != "healthy" ]; do
      printf "."
      sleep 2
    done
  done
  echo ""
  ok "Postgres + Redis running (Docker)"

  # 3b. Swift/Vapor backend, on the host (reads ../backend/.env; migrations
  #     replay at boot via RUN_MIGRATIONS=1, advisory-locked and idempotent).
  log "Starting Swift backend (host: swift run App serve)..."
  if lsof -nP -iTCP:3000 -sTCP:LISTEN > /dev/null 2>&1; then
    ok "Backend already listening on :3000"
  else
    cd "$SERVER_DIR"
    RUN_MIGRATIONS=1 RUN_JOBS=1 PORT=3000 nohup swift run App serve > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    echo "   Waiting for the backend to be healthy (first run compiles Swift. This is slow)"
    tries=0
    while ! curl -sf http://localhost:3000/health > /dev/null 2>&1; do
      if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo ""
        err "Swift backend exited before it came up. Check $SERVER_LOG"
        tail -n 20 "$SERVER_LOG"
        return 1
      fi
      tries=$((tries + 1))
      if [ "$tries" -gt 180 ]; then   # ~6 min
        echo ""
        err "Backend not healthy after 6 min. Check $SERVER_LOG"
        return 1
      fi
      printf "."
      sleep 2
    done
    echo ""
    ok "Swift backend running on :3000 (host). Logs: $SERVER_LOG"
  fi

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
  echo "  Backend : http://localhost:3000  (host: swift run App serve)"
  echo "  Ollama  : http://localhost:11434 (host process)"
  echo "  Postgres: localhost:5432         (container: connectsphere_db)"
  echo "  Redis   : localhost:6379         (container: connectsphere_redis)"
  echo "  Logs    : tail -f $SERVER_LOG"
  echo ""
}

# ─────────────────────────────────────────
stop() {
  echo ""
  echo "${RED}╔══════════════════════════════╗${NC}"
  echo "${RED}║   ConnectSphere, Stopping   ║${NC}"
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

  # 3. Swift backend (host process)
  log "Stopping Swift backend..."
  if pkill -f 'App serve' 2>/dev/null; then
    ok "Swift backend stopped"
  else
    warn "Swift backend was not running"
  fi

  # 4. Ollama (host process)
  log "Stopping Ollama..."
  if pkill -x "ollama" 2>/dev/null; then
    ok "Ollama stopped"
  else
    warn "Ollama was not running"
  fi

  # 5. Docker data layer: PostgreSQL + Redis
  log "Stopping Docker data layer (Postgres, Redis)..."
  cd "$BACKEND_DIR"
  docker compose down > /dev/null 2>&1 && ok "Docker services stopped" || warn "Docker services were not running"

  # 8. Docker Desktop, wait for containers to stop first
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
    echo "  start ,  Docker (Postgres + Redis) + Ollama + Swift backend (host) + Xcode + VS Code + TablePlus"
    echo "  stop  ,  Stop everything and close Xcode"
    ;;
esac
