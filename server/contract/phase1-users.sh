#!/usr/bin/env bash
# Phase 1 users contract check. Restart the Node backend first so its
# passwordAuthLimiter is fresh (register/change-password count against it).
set -u
ORACLE="${ORACLE:-http://localhost:3000}"
PORT="${PORT:-http://localhost:8080}"
PASS=0; FAIL=0

norm() {
  python3 - "$1" <<'PY'
import sys, json
VOL = {"token","id","created_at","updated_at","iat","exp","blocked_at"}
def n(v):
    if isinstance(v, list): return [n(x) for x in v]
    if isinstance(v, dict): return {k: ("<v>" if k in VOL else n(v[k])) for k in sorted(v)}
    return v
try: print(json.dumps(n(json.loads(sys.argv[1])), sort_keys=True))
except Exception: print(json.dumps({"__raw__": sys.argv[1][:300]}))
PY
}

# Register one shared account per server (its token drives the reads).
mk() { curl -s -X POST "$1/api/auth/register" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$2\",\"password\":\"password123\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))'; }
TS="pu_$(date +%s)_$RANDOM"
TN=$(mk "$ORACLE" "${TS}n"); TSK=$(mk "$PORT" "${TS}s")
[ -z "$TN" ] || [ -z "$TSK" ] && { echo "register failed (rate limited?) — restart connectsphere_backend"; exit 2; }

cmp_auth() { # name method path token_node token_swift [body]
  local name="$1" method="$2" path="$3" tn="$4" ts="$5" body="${6:-}" o s
  if [ -n "$body" ]; then
    o=$(curl -s -X "$method" "$ORACLE$path" -H "Authorization: Bearer $tn" -H 'Content-Type: application/json' -d "$body")
    s=$(curl -s -X "$method" "$PORT$path"   -H "Authorization: Bearer $ts" -H 'Content-Type: application/json' -d "$body")
  else
    o=$(curl -s -X "$method" "$ORACLE$path" -H "Authorization: Bearer $tn")
    s=$(curl -s -X "$method" "$PORT$path"   -H "Authorization: Bearer $ts")
  fi
  # Both test users live in the one shared DB, so a list can contain either —
  # mask both regardless of which server produced the body.
  o=$(norm "$o" | sed "s/${TS}[ns]/<u>/g"); s=$(norm "$s" | sed "s/${TS}[ns]/<u>/g")
  if [ "$o" = "$s" ]; then echo "  ok   $name"; PASS=$((PASS+1))
  else echo "  FAIL $name"; echo "     node: $o"; echo "     swift:$s"; FAIL=$((FAIL+1)); fi
}

# A well-known setup user for /users/:id and blocking.
OTHER=$(docker exec connectsphere_db psql -U connectsphere_user -d connectsphere -tAc "SELECT id FROM users WHERE username='duonghung' LIMIT 1;" | tr -d ' \n')

cmp_auth "users/list-default"       GET  "/api/users?limit=3"            "$TN" "$TSK"
cmp_auth "users/list-mode-work"     GET  "/api/users?limit=3&mode=work"  "$TN" "$TSK"
cmp_auth "users/list-search"        GET  "/api/users?limit=3&search=eng" "$TN" "$TSK"
cmp_auth "users/get-by-id"          GET  "/api/users/$OTHER"             "$TN" "$TSK"
cmp_auth "users/get-by-id-mode"     GET  "/api/users/$OTHER?mode=work"   "$TN" "$TSK"
cmp_auth "users/get-missing"        GET  "/api/users/00000000-0000-0000-0000-000000000000" "$TN" "$TSK"
cmp_auth "users/blocked-list-empty" GET  "/api/users/blocked"            "$TN" "$TSK"
cmp_auth "users/block-status"       GET  "/api/users/$OTHER/blocked"     "$TN" "$TSK"
cmp_auth "users/default-mode"       PATCH "/api/users/me/default-mode"   "$TN" "$TSK" '{"mode":"work"}'
cmp_auth "users/default-mode-bad"   PATCH "/api/users/me/default-mode"   "$TN" "$TSK" '{"mode":"nope"}'
cmp_auth "users/patch-me"           PATCH "/api/users/me?mode=work"      "$TN" "$TSK" '{"display_name":"Renamed","bio":"new bio","job_title":"SRE","skills":["Go","Rust","Go"]}'
cmp_auth "users/patch-me-badgender" PATCH "/api/users/me"               "$TN" "$TSK" '{"gender":"zzz"}'
cmp_auth "users/create-persona"     POST "/api/users/me/personas"        "$TN" "$TSK" '{"mode":"hobby","display_name":"Hobby Me","interests":["Chess"]}'
cmp_auth "users/create-persona-dup" POST "/api/users/me/personas"        "$TN" "$TSK" '{"mode":"hobby","display_name":"Again"}'
cmp_auth "users/block"              POST "/api/users/$OTHER/block"       "$TN" "$TSK"
cmp_auth "users/blocked-list-1"     GET  "/api/users/blocked"            "$TN" "$TSK"
cmp_auth "users/block-status-2"     GET  "/api/users/$OTHER/blocked"     "$TN" "$TSK"
cmp_auth "users/unblock"            DELETE "/api/users/$OTHER/block"     "$TN" "$TSK"
SN=$(curl -s "$ORACLE/api/auth/me" -H "Authorization: Bearer $TN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["user"]["id"])')
SS=$(curl -s "$PORT/api/auth/me"   -H "Authorization: Bearer $TSK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["user"]["id"])')
on=$(norm "$(curl -s -X POST "$ORACLE/api/users/$SN/block" -H "Authorization: Bearer $TN")")
os=$(norm "$(curl -s -X POST "$PORT/api/users/$SS/block"   -H "Authorization: Bearer $TSK")")
[ "$on" = "$os" ] && { echo "  ok   users/block-self"; PASS=$((PASS+1)); } || { echo "  FAIL users/block-self"; echo "   node:$on"; echo "   swift:$os"; FAIL=$((FAIL+1)); }

echo
echo "$PASS passed, $FAIL failed"
exit $((FAIL>0))
