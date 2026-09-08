#!/usr/bin/env bash
# Phase 1 auth contract check. Fires the same requests at the Node oracle and the
# Swift port; compares status + normalised JSON. The Node `passwordAuthLimiter`
# is 10/15min per IP, so this script is kept lean and the caller should
# `docker restart connectsphere_backend` right before running it.
# Requires: node backend on $ORACLE (:3000), swift server on $PORT (:8080), python3.
set -u
ORACLE="${ORACLE:-http://localhost:3000}"
PORT="${PORT:-http://localhost:8080}"
PASS=0; FAIL=0

norm() {
  python3 - "$1" <<'PY'
import sys, json
VOL = {"token","id","created_at","updated_at","iat","exp","applied_at"}
def n(v):
    if isinstance(v, list): return [n(x) for x in v]
    if isinstance(v, dict): return {k: ("<v>" if k in VOL else n(v[k])) for k in sorted(v)}
    return v
try: print(json.dumps(n(json.loads(sys.argv[1])), sort_keys=True))
except Exception: print(json.dumps({"__raw__": sys.argv[1][:200]}))
PY
}
check() { # name method path [body] [header]
  local name="$1" method="$2" path="$3" body="${4:-}" hdr="${5:-}" oc os ob sb
  if [ -n "$body" ]; then
    oc=$(curl -s -o /tmp/o.json -w '%{http_code}' -X "$method" "$ORACLE$path" -H 'Content-Type: application/json' ${hdr:+-H "$hdr"} -d "$body")
    os=$(curl -s -o /tmp/s.json -w '%{http_code}' -X "$method" "$PORT$path"   -H 'Content-Type: application/json' ${hdr:+-H "$hdr"} -d "$body")
  else
    oc=$(curl -s -o /tmp/o.json -w '%{http_code}' -X "$method" "$ORACLE$path" ${hdr:+-H "$hdr"})
    os=$(curl -s -o /tmp/s.json -w '%{http_code}' -X "$method" "$PORT$path"   ${hdr:+-H "$hdr"})
  fi
  ob=$(norm "$(cat /tmp/o.json)"); sb=$(norm "$(cat /tmp/s.json)")
  if [ "$oc" = "$os" ] && [ "$ob" = "$sb" ]; then echo "  ok   $name"; PASS=$((PASS+1))
  else echo "  FAIL $name"; [ "$oc" != "$os" ] && echo "       status oracle=$oc port=$os"
       [ "$ob" != "$sb" ] && { echo "       oracle: $ob"; echo "       port:   $sb"; }; FAIL=$((FAIL+1)); fi
}

TS="p1_$(date +%s)_$RANDOM"

# 1. Stateful happy path first (uses the most limiter budget): register -> setup
#    -> change-password -> me, run identically on each server, compare final /me.
flow() {
  local base="$1" u="$2" tok
  tok=$(curl -s -X POST "$base/api/auth/register" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$u\",\"password\":\"password123\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
  [ -z "$tok" ] && { echo "REGISTER-FAILED"; return; }
  curl -s -X POST "$base/api/auth/setup" -H 'Content-Type: application/json' -H "Authorization: Bearer $tok" \
    -d "{\"username\":\"$u\",\"display_name\":\"Test Person\",\"dob\":\"1995-06-15\",\"dob_visibility\":\"public\",\"bio\":\"hi\",\"location\":\"Ha Noi\",\"default_mode\":\"work\",\"job_title\":\"Eng\",\"company\":\"Acme\",\"gender\":\"female\",\"skills\":[\"Swift\",\"Vapor\",\"Swift\"],\"interests\":[\"Hiking\"]}" >/dev/null
  curl -s -X POST "$base/api/auth/change-password" -H 'Content-Type: application/json' -H "Authorization: Bearer $tok" \
    -d '{"current_password":"password123","new_password":"newpassword456"}' >/dev/null
  curl -s "$base/api/auth/me" -H "Authorization: Bearer $tok"
}
MO=$(flow "$ORACLE" "${TS}n"); MS=$(flow "$PORT" "${TS}s")
mo=$(norm "$MO" | sed "s/${TS}n/<u>/g"); ms=$(norm "$MS" | sed "s/${TS}s/<u>/g")
if [ "$mo" = "$ms" ] && [ -n "$mo" ] && [ "$mo" != "$(norm REGISTER-FAILED)" ]; then
  echo "  ok   flow/register-setup-changepw-me"; PASS=$((PASS+1))
else echo "  FAIL flow/register-setup-changepw-me"; echo "   node: $mo"; echo "   swift:$ms"; FAIL=$((FAIL+1)); fi

# 2. Cross-token: JWT minted by Node verifies on Swift and returns the same /me.
TOK=$(curl -s -X POST "$ORACLE/api/auth/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"${TS}n\",\"password\":\"newpassword456\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
if [ -n "$TOK" ]; then
  x1=$(norm "$(curl -s "$ORACLE/api/auth/me" -H "Authorization: Bearer $TOK")" | sed "s/${TS}n/<u>/g")
  x2=$(norm "$(curl -s "$PORT/api/auth/me"   -H "Authorization: Bearer $TOK")" | sed "s/${TS}n/<u>/g")
  [ "$x1" = "$x2" ] && [ -n "$x1" ] && { echo "  ok   xtoken/me"; PASS=$((PASS+1)); } || { echo "  FAIL xtoken/me"; echo "   $x1"; echo "   $x2"; FAIL=$((FAIL+1)); }
else echo "  SKIP xtoken/me (login rate-limited)"; fi

# 3. Single-shot validation / error cases (cheap, one hit each).
check "register/bad-username"  POST /api/auth/register '{"username":"AB","password":"password123"}'
check "login/missing"          POST /api/auth/login '{"username":"x"}'
check "me/no-token"            GET  /api/auth/me
check "me/bad-token"           GET  /api/auth/me "" "Authorization: Bearer not.a.jwt"
check "google/missing"         POST /api/auth/google '{}'
check "google/bad"             POST /api/auth/google '{"id_token":"clearlyinvalid"}'
check "check-username/no-token" GET  "/api/auth/check-username?username=whatever"
check "reset/bad-code"         POST /api/auth/reset-password '{"identifier":"nobody","otp":"000000","new_password":"password123"}'
check "forgot/unknown"         POST /api/auth/forgot-password '{"identifier":"definitely_nobody_here"}'

echo
echo "$PASS passed, $FAIL failed"
exit $((FAIL>0))
