#!/usr/bin/env bash
# Load test for the Home feed and AI search, against a private server on :3002.
#
#   scripts/loadtest.sh
#   LOADTEST_FEED_USERS=10,50,100 LOADTEST_SEARCH_USERS=1,4 scripts/loadtest.sh
#
# Starts the server with the /api/test hooks and LOAD_TEST=1 (loopback only;
# the per-IP rate limits are raised, no real mail, no jobs; :3000 is never
# touched), runs scripts/loadtest.py, stops the server, then checks no qa_ui_
# account is left. Needs Postgres + Redis up and Ollama running (./dev.sh start).
#
# Steps (override with env): LOADTEST_FEED_USERS (10,25,50), LOADTEST_FEED_SECONDS
# (30), LOADTEST_SEARCH_USERS (1,2,4,8), LOADTEST_SEARCHES_EACH (3).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${LOADTEST_PORT:-3002}"
LOG="${LOADTEST_LOG:-/tmp/connectsphere-loadtest.log}"
DB_CONTAINER="${DB_CONTAINER:-connectsphere_db}"

psql_count() {
  docker exec "$DB_CONTAINER" psql -U "$(grep '^DB_USER=' "$ROOT/backend/.env" | cut -d= -f2)" \
    -d "$(grep '^DB_NAME=' "$ROOT/backend/.env" | cut -d= -f2)" -tAc "$1"
}

docker ps --format '{{.Names}}' | grep -q "^$DB_CONTAINER$" \
  || { echo "Postgres isn't running: ./dev.sh start" >&2; exit 1; }
curl -sf -m 3 http://localhost:11434/api/tags >/dev/null \
  || { echo "Ollama isn't running (AI search needs it): ollama serve" >&2; exit 1; }
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null; then
  echo "Port $PORT is already in use." >&2; exit 1
fi

TOKEN="$(openssl rand -hex 24)"

echo "Building the server…"
(cd "$ROOT/server" && swift build --product App >/dev/null)
BIN="$(cd "$ROOT/server" && swift build --show-bin-path)/App"

echo "Starting the load-test server on :$PORT (log: $LOG)"
(cd "$ROOT/server" && UITEST_HOOKS=1 LOAD_TEST=1 UITEST_TOKEN="$TOKEN" BREVO_API_KEY= \
  RUN_MIGRATIONS=0 RUN_JOBS=0 PORT="$PORT" "$BIN" serve >"$LOG" 2>&1) &
SERVER_PID=$!
cleanup() { pkill -P "$SERVER_PID" 2>/dev/null || true; kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 60); do
  curl -sf "http://localhost:$PORT/health" >/dev/null && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "The server exited; see $LOG" >&2; exit 1; }
  sleep 0.5
done
curl -sf "http://localhost:$PORT/health" >/dev/null || { echo "The server never came up; see $LOG" >&2; exit 1; }

set +e
LOADTEST_SERVER="http://localhost:$PORT" LOADTEST_TOKEN="$TOKEN" python3 "$ROOT/scripts/loadtest.py"
STATUS=$?
set -e

cleanup
trap - EXIT

LEFT="$(psql_count "SELECT COUNT(*) FROM users WHERE username ~ '^qa_ui_[a-z0-9]{8}_[0-9]+\$'")"
if [ "$LEFT" != "0" ]; then
  echo "WARNING: $LEFT qa_ui_ account(s) left behind. Remove them with: cd server && swift run App seed-demo wipe --commit" >&2
  [ "$STATUS" = 0 ] && STATUS=3
else
  echo "Clean: no qa_ui_ accounts left."
fi
exit "$STATUS"
