#!/usr/bin/env bash
# Runs the XCUITest suite against a private UI-test server on :3001.
#
#   scripts/uitest.sh                                   # every UI test
#   scripts/uitest.sh -only-testing:ConnectSphereUITests/AuthTests
#
# Starts the server with the /api/test hooks (UITEST_HOOKS=1, a fresh token,
# no real mail, no jobs; :3000 keeps those), runs the tests on the one
# iPhone 17 simulator, stops the server, then checks no qa_ui_ account is left.
# Needs Postgres + Redis up (./dev.sh start) and the simulator booted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM_ID="${UITEST_SIM_ID:-208E432A-1CF4-46EE-989A-81246C46A969}"
PORT="${UITEST_PORT:-3001}"
LOG="${UITEST_LOG:-/tmp/connectsphere-uitest.log}"
RESULT="${UITEST_RESULT:-/tmp/connectsphere-uitest.xcresult}"
DB_CONTAINER="${DB_CONTAINER:-connectsphere_db}"

psql_count() {
  docker exec "$DB_CONTAINER" psql -U "$(grep '^DB_USER=' "$ROOT/backend/.env" | cut -d= -f2)" \
    -d "$(grep '^DB_NAME=' "$ROOT/backend/.env" | cut -d= -f2)" -tAc "$1"
}

xcrun simctl list devices booted | grep -q "$SIM_ID" \
  || { echo "Boot the iPhone 17 simulator ($SIM_ID) first." >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -q "^$DB_CONTAINER$" \
  || { echo "Postgres isn't running: ./dev.sh start" >&2; exit 1; }
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null; then
  echo "Port $PORT is already in use." >&2; exit 1
fi

TOKEN="$(openssl rand -hex 24)"

echo "Building the server…"
(cd "$ROOT/server" && swift build --product App >/dev/null)
BIN="$(cd "$ROOT/server" && swift build --show-bin-path)/App"

echo "Starting the UI-test server on :$PORT (log: $LOG)"
(cd "$ROOT/server" && UITEST_HOOKS=1 UITEST_TOKEN="$TOKEN" BREVO_API_KEY= \
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

# A caller's own -only-testing narrows the run; otherwise every UI test.
ONLY=(-only-testing:ConnectSphereUITests)
for arg in "$@"; do [[ "$arg" == -only-testing:* ]] && ONLY=(); done

rm -rf "$RESULT"
set +e
TEST_RUNNER_UITEST_TOKEN="$TOKEN" TEST_RUNNER_UITEST_SERVER="http://localhost:$PORT" \
xcodebuild test \
  -project "$ROOT/ConnectSphere.xcodeproj" -scheme ConnectSphere \
  -destination "id=$SIM_ID" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 240 -maximum-test-execution-time-allowance 300 \
  ${ONLY[@]+"${ONLY[@]}"} -resultBundlePath "$RESULT" "$@"
STATUS=$?
set -e

# A test killed by its time limit never reaches its teardown: delete what its
# run left while the server (and its hook) is still up.
for run in $(psql_count "SELECT DISTINCT substring(username from '^qa_ui_([a-z0-9]{8})_') FROM users WHERE username ~ '^qa_ui_[a-z0-9]{8}_[0-9]+\$'"); do
  echo "Deleting what run $run left behind"
  curl -sf -X DELETE -H "X-UITest-Token: $TOKEN" "http://localhost:$PORT/api/test/runs/$run" >/dev/null || true
done

cleanup
trap - EXIT

LEFT="$(psql_count "SELECT COUNT(*) FROM users WHERE username ~ '^qa_ui_[a-z0-9]{8}_[0-9]+\$'")"
if [ "$LEFT" != "0" ]; then
  echo "WARNING: $LEFT qa_ui_ account(s) left behind. Remove them with: cd server && swift run App seed-demo wipe --commit" >&2
  [ "$STATUS" = 0 ] && STATUS=3
else
  echo "Clean: no qa_ui_ accounts left."
fi
echo "Results: $RESULT"
exit "$STATUS"
