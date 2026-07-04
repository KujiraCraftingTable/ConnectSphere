#!/bin/zsh

# ConnectSphere dev workflow manager
# Usage: ./dev.sh start | stop

PROJECT_DIR="/Users/triminh/Desktop/COMP1682/ConnectSphere"
BACKEND_DIR="$PROJECT_DIR/backend"
XCODE_PROJECT="$PROJECT_DIR/ConnectSphere.xcodeproj"

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

  # 2. Docker Compose (PostgreSQL)
  log "Starting PostgreSQL..."
  cd "$BACKEND_DIR"
  if docker compose ps | grep -q "running"; then
    ok "PostgreSQL already running"
  else
    docker compose up -d > /dev/null 2>&1
    sleep 2
    ok "PostgreSQL started"
  fi

  # 3. Redis
  log "Starting Redis..."
  if redis-cli ping > /dev/null 2>&1; then
    ok "Redis already running"
  else
    redis-server > /tmp/redis.log 2>&1 &
    sleep 1
    if redis-cli ping > /dev/null 2>&1; then
      ok "Redis started (port 6379)"
    else
      err "Redis failed to start — check /tmp/redis.log"
    fi
  fi

  # 4. Ollama server
  log "Starting Ollama server..."
  if pgrep -x "ollama" > /dev/null; then
    ok "Ollama already running"
  else
    ollama serve > /tmp/ollama.log 2>&1 &
    sleep 2
    ok "Ollama server started (port 11434)"
  fi

  # 5. Backend Node.js
  log "Starting backend server..."
  if pgrep -f "node index.js" > /dev/null; then
    ok "Backend already running"
  else
    cd "$BACKEND_DIR"
    npm run dev > /tmp/connectsphere-backend.log 2>&1 &
    sleep 2
    ok "Backend started (port 3000)"
  fi

  # 6. Xcode
  log "Opening Xcode..."
  open "$XCODE_PROJECT"
  ok "Xcode opened"

  # 7. VS Code
  log "Opening VS Code..."
  open -a "Visual Studio Code" "$PROJECT_DIR"
  ok "VS Code opened"

  # 8. TablePlus
  log "Opening TablePlus..."
  open -a TablePlus
  ok "TablePlus opened"

  echo ""
  echo "${GREEN}╔══════════════════════════════╗${NC}"
  echo "${GREEN}║   All services are running   ║${NC}"
  echo "${GREEN}╚══════════════════════════════╝${NC}"
  echo ""
  echo "  Backend : http://localhost:3000"
  echo "  Ollama  : http://localhost:11434"
  echo "  Redis   : localhost:6379"
  echo "  Logs    : tail -f /tmp/connectsphere-backend.log"
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

  # 3. Backend
  log "Stopping backend..."
  if pkill -f "node index.js" 2>/dev/null; then ok "Backend stopped"
  elif pkill -f "nodemon" 2>/dev/null;    then ok "Backend stopped"
  else warn "Backend was not running"; fi

  # 4. Ollama
  log "Stopping Ollama..."
  if pkill -x "ollama" 2>/dev/null; then
    ok "Ollama stopped"
  else
    warn "Ollama was not running"
  fi

  # 5. Redis
  log "Stopping Redis..."
  if redis-cli ping > /dev/null 2>&1; then
    redis-cli shutdown nosave > /dev/null 2>&1
    ok "Redis stopped"
  else
    warn "Redis was not running"
  fi

  # 7. Docker Compose (PostgreSQL)
  log "Stopping PostgreSQL containers..."
  cd "$BACKEND_DIR"
  docker compose down > /dev/null 2>&1 && ok "PostgreSQL stopped" || warn "PostgreSQL was not running"

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
