#!/usr/bin/env bash
# Phase 3 (communities + connections + reports). Restart connectsphere_backend first.
set -u
ORACLE="${ORACLE:-http://localhost:3000}"; PORT="${PORT:-http://localhost:8080}"
PASS=0; FAIL=0
norm() {
  python3 - "$1" <<'PY'
import sys, json, re
VOL={"token","id","created_at","updated_at","requested_at","reviewed_at","resolved_at","joined_at",
     "connection_id","requestId","request_id","reviewed_by","reporter_id","target_id","community_id","user_id",
     "created_by","actor_id","post_id","entity_id","trending_score","score"}
ISO=re.compile(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:?\d\d)$')
def n(v):
  if isinstance(v,list): return [n(x) for x in v]
  if isinstance(v,dict): return {k:("<v>" if k in VOL else n(v[k])) for k in sorted(v)}
  if isinstance(v,str): return "<ts>" if ISO.match(v) else v
  return v
try: print(json.dumps(n(json.loads(sys.argv[1])),sort_keys=True))
except Exception: print(json.dumps({"__raw__":sys.argv[1][:400]}))
PY
}
mk(){ curl -s -X POST "$1/api/auth/register" -H 'Content-Type: application/json' -d "{\"username\":\"$2\",\"password\":\"password123\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))'; }
cmp(){ local name="$1" method="$2" path="$3" tn="$4" ts="$5" body="${6:-}" o s
  if [ -n "$body" ]; then
    o=$(curl -s -X "$method" "$ORACLE$path" -H "Authorization: Bearer $tn" -H 'Content-Type: application/json' -d "$body")
    s=$(curl -s -X "$method" "$PORT$path"   -H "Authorization: Bearer $ts" -H 'Content-Type: application/json' -d "$body")
  else
    o=$(curl -s -X "$method" "$ORACLE$path" -H "Authorization: Bearer $tn")
    s=$(curl -s -X "$method" "$PORT$path"   -H "Authorization: Bearer $ts")
  fi
  o=$(norm "$o"); s=$(norm "$s")
  if [ "$o" = "$s" ]; then echo "  ok   $name"; PASS=$((PASS+1)); else echo "  FAIL $name"; echo "     node:${o:0:400}"; echo "     swift:${s:0:400}"; FAIL=$((FAIL+1)); fi
}
TS="p3_$(date +%s)_$RANDOM"
TN=$(mk "$ORACLE" "${TS}n"); TSK=$(mk "$PORT" "${TS}s")
[ -z "$TN" ] || [ -z "$TSK" ] && { echo "register failed — restart connectsphere_backend"; exit 2; }
CIDPUB=$(docker exec connectsphere_db psql -U connectsphere_user -d connectsphere -tAc "SELECT id FROM communities WHERE privacy='public' LIMIT 1;"|tr -d ' \n')
CIDPRIV=$(docker exec connectsphere_db psql -U connectsphere_user -d connectsphere -tAc "SELECT id FROM communities WHERE privacy='private' LIMIT 1;"|tr -d ' \n')
OTHER=$(docker exec connectsphere_db psql -U connectsphere_user -d connectsphere -tAc "SELECT id FROM users WHERE username='duonghung' LIMIT 1;"|tr -d ' \n')

cmp "comm/me"             GET  "/api/communities/me" "$TN" "$TSK"
cmp "comm/search"         GET  "/api/communities?limit=3" "$TN" "$TSK"
cmp "comm/search-type"    GET  "/api/communities?limit=3&type=fandom&sort=newest" "$TN" "$TSK"
cmp "comm/get-public"     GET  "/api/communities/$CIDPUB" "$TN" "$TSK"
cmp "comm/get-private"    GET  "/api/communities/$CIDPRIV" "$TN" "$TSK"
cmp "comm/get-missing"    GET  "/api/communities/00000000-0000-0000-0000-000000000000" "$TN" "$TSK"
cmp "comm/members-public" GET  "/api/communities/$CIDPUB/members?limit=3" "$TN" "$TSK"
cmp "comm/members-priv-403" GET "/api/communities/$CIDPRIV/members" "$TN" "$TSK"
cmp "comm/posts-public"   GET  "/api/communities/$CIDPUB/posts?limit=2" "$TN" "$TSK"
cmp "comm/create-badtype" POST "/api/communities" "$TN" "$TSK" '{"name":"Test Comm","type":"nope"}'
cmp "comm/create-shortname" POST "/api/communities" "$TN" "$TSK" '{"name":"ab","type":"fandom"}'
cmp "comm/join-private-403" POST "/api/communities/$CIDPRIV/join" "$TN" "$TSK"
cmp "comm/join-missing"   POST "/api/communities/00000000-0000-0000-0000-000000000000/join" "$TN" "$TSK"
cmp "comm/leave-notmember" DELETE "/api/communities/$CIDPUB/leave" "$TN" "$TSK"
cmp "comm/joinreqs-403"   GET  "/api/communities/$CIDPUB/join-requests" "$TN" "$TSK"
cmp "comm/moderation-403" GET  "/api/communities/$CIDPUB/moderation" "$TN" "$TSK"
cmp "comm/recommendations" GET "/api/communities/recommendations?limit=3" "$TN" "$TSK"
cmp "comm/trending"       GET  "/api/communities/trending?limit=3" "$TN" "$TSK"
cmp "comm/discover"       GET  "/api/communities/discover" "$TN" "$TSK"
cmp "comm/kick-notstaff"  DELETE "/api/communities/$CIDPUB/members/$OTHER" "$TN" "$TSK"
cmp "comm/reviewreq-badstatus" PATCH "/api/communities/$CIDPUB/join-requests/00000000-0000-0000-0000-000000000000" "$TN" "$TSK" '{"status":"zzz"}'

cmp "conn/list"           GET  "/api/connections" "$TN" "$TSK"
cmp "conn/list-pending"   GET  "/api/connections?status=pending_received" "$TN" "$TSK"
cmp "conn/status-self"    GET  "/api/connections/status/SELF" "$TN" "$TSK"
cmp "conn/status-other"   GET  "/api/connections/status/$OTHER" "$TN" "$TSK"
cmp "conn/request-noaddr" POST "/api/connections/request" "$TN" "$TSK" '{}'
cmp "conn/request-badmode" POST "/api/connections/request" "$TN" "$TSK" "{\"addressee_id\":\"$OTHER\",\"mode\":\"zz\"}"
cmp "conn/accept-noid"    POST "/api/connections/accept" "$TN" "$TSK" '{}'
cmp "conn/accept-missing" POST "/api/connections/accept" "$TN" "$TSK" '{"connection_id":"00000000-0000-0000-0000-000000000000"}'
cmp "conn/decline-missing" POST "/api/connections/decline" "$TN" "$TSK" '{"connection_id":"00000000-0000-0000-0000-000000000000"}'
cmp "conn/cancel-missing" POST "/api/connections/cancel" "$TN" "$TSK" '{"connection_id":"00000000-0000-0000-0000-000000000000"}'
cmp "conn/remove-missing" POST "/api/connections/remove" "$TN" "$TSK" '{"connection_id":"00000000-0000-0000-0000-000000000000"}'

# stateful: create a community on each, read it back, add tags, list my communities
flow(){ local base="$1" tok="$2" nm="$3"
  local cid
  cid=$(curl -s -X POST "$base/api/communities" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$nm\",\"type\":\"fandom\",\"description\":\"a test community\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
  curl -s -X POST "$base/api/communities/$cid/tags" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"tags":["testtag","alpha","testtag"]}' >/dev/null
  echo "GET:"; curl -s "$base/api/communities/$cid" -H "Authorization: Bearer $tok"; echo
  echo "ME:"; curl -s "$base/api/communities/me" -H "Authorization: Bearer $tok"; echo
  echo "POST:"; curl -s -X POST "$base/api/communities/$cid/posts" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"content":"first community post"}'; echo
}
FN=$(flow "$ORACLE" "$TN" "${TS}n Community"); FS=$(flow "$PORT" "$TSK" "${TS}s Community")
for sec in GET ME POST; do
  a=$(echo "$FN"|awk "/^$sec:/{getline;print}"|sed "s/${TS}n/<u>/g"); b=$(echo "$FS"|awk "/^$sec:/{getline;print}"|sed "s/${TS}s/<u>/g")
  na=$(norm "$a"); nb=$(norm "$b")
  if [ "$na" = "$nb" ]; then echo "  ok   flow/$sec"; PASS=$((PASS+1)); else echo "  FAIL flow/$sec"; echo "     node:${na:0:400}"; echo "     swift:${nb:0:400}"; FAIL=$((FAIL+1)); fi
done

echo; echo "$PASS passed, $FAIL failed"; exit $((FAIL>0))
