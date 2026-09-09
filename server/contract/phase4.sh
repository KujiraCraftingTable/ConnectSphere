#!/usr/bin/env bash
# Phase 4a chat REST core. Restart connectsphere_backend first.
set -u
ORACLE="${ORACLE:-http://localhost:3000}"; PORT="${PORT:-http://localhost:8080}"
PASS=0; FAIL=0
norm() {
  python3 - "$1" <<'PY'
import sys,json,re
VOL={"id","created_at","updated_at","token","conversation_id","sender_id","message_id","user_id",
     "other_user_id","last_message_at","muted_until","reply_to_message_id","pinned_at","pinned_by",
     "last_message_sender_id","created_by","expires_at","reminder_at","sender_name"}
ISO=re.compile(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:?\d\d)$')
UUID=re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
def n(v):
  if isinstance(v,list): return [n(x) for x in v]
  if isinstance(v,dict): return {k:("<v>" if k in VOL else n(v[k])) for k in sorted(v)}
  if isinstance(v,str): return "<ts>" if ISO.match(v) else ("<uuid>" if UUID.match(v) else v)
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
TS="p4_$(date +%s)_$RANDOM"
TN=$(mk "$ORACLE" "${TS}n"); TSK=$(mk "$PORT" "${TS}s")
[ -z "$TN" ] || [ -z "$TSK" ] && { echo "register failed"; exit 2; }
OTHER=$(docker exec connectsphere_db psql -U connectsphere_user -d connectsphere -tAc "SELECT id FROM users WHERE username='duonghung' LIMIT 1;"|tr -d ' \n')

cmp "conv/list-nomode"   GET  "/api/messages/conversations" "$TN" "$TSK"
cmp "conv/list"          GET  "/api/messages/conversations?mode=hobby" "$TN" "$TSK"
cmp "conv/open-self"     POST "/api/messages/conversations" "$TN" "$TSK" "{\"other_user_id\":\"$OTHER\",\"mode\":\"badmode\"}"
cmp "unread-nomode"      GET  "/api/messages/unread" "$TN" "$TSK"
cmp "unread"             GET  "/api/messages/unread?mode=hobby" "$TN" "$TSK"
cmp "msgs-404"           GET  "/api/messages/conversations/00000000-0000-0000-0000-000000000000/messages" "$TN" "$TSK"
cmp "settings-404"       GET  "/api/messages/conversations/00000000-0000-0000-0000-000000000000/settings" "$TN" "$TSK"
cmp "send-404"           POST "/api/messages/conversations/00000000-0000-0000-0000-000000000000/messages" "$TN" "$TSK" '{"content":"hi"}'
cmp "read-404"           PUT  "/api/messages/conversations/00000000-0000-0000-0000-000000000000/read" "$TN" "$TSK"
cmp "pins-404"           GET  "/api/messages/conversations/00000000-0000-0000-0000-000000000000/pins" "$TN" "$TSK"
cmp "media-404"          GET  "/api/messages/conversations/00000000-0000-0000-0000-000000000000/media" "$TN" "$TSK"

# stateful: open a 1:1, send text + reply + image, list, react, read, unread, settings, pins, clear
flow(){ local base="$1" tok="$2"
  local cid m1 m2
  cid=$(curl -s -X POST "$base/api/messages/conversations" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d "{\"other_user_id\":\"$OTHER\",\"mode\":\"hobby\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
  m1=$(curl -s -X POST "$base/api/messages/conversations/$cid/messages" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d '{"content":"hello there"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
  curl -s -X POST "$base/api/messages/conversations/$cid/messages" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d "{\"content\":\"a reply\",\"reply_to_message_id\":\"$m1\"}" >/dev/null
  curl -s -X POST "$base/api/messages/conversations/$cid/messages" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d '{"message_type":"image","media_url":"/uploads/messages/x.jpg"}' >/dev/null
  curl -s -X POST "$base/api/messages/conversations/$cid/messages/$m1/reactions" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"emoji":"🔥"}' >/dev/null
  curl -s -X POST "$base/api/messages/conversations/$cid/pins" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "{\"message_id\":\"$m1\"}" >/dev/null
  echo "MSGS:"; curl -s "$base/api/messages/conversations/$cid/messages?limit=5" -H "Authorization: Bearer $tok"; echo
  echo "SETTINGS:"; curl -s "$base/api/messages/conversations/$cid/settings" -H "Authorization: Bearer $tok"; echo
  echo "PINS:"; curl -s "$base/api/messages/conversations/$cid/pins" -H "Authorization: Bearer $tok"; echo
  echo "SEARCH:"; curl -s "$base/api/messages/conversations/$cid/messages/search?q=hello" -H "Authorization: Bearer $tok"; echo
  echo "MEDIA:"; curl -s "$base/api/messages/conversations/$cid/media" -H "Authorization: Bearer $tok"; echo
}
FN=$(flow "$ORACLE" "$TN"); FS=$(flow "$PORT" "$TSK")
for sec in MSGS SETTINGS PINS SEARCH MEDIA; do
  a=$(echo "$FN"|awk "/^$sec:/{getline;print}"); b=$(echo "$FS"|awk "/^$sec:/{getline;print}")
  a=$(echo "$a"|sed "s/${TS}n/<u>/g"); b=$(echo "$b"|sed "s/${TS}s/<u>/g"); na=$(norm "$a"); nb=$(norm "$b")
  if [ "$na" = "$nb" ]; then echo "  ok   flow/$sec"; PASS=$((PASS+1)); else echo "  FAIL flow/$sec"; echo "     node:${na:0:500}"; echo "     swift:${nb:0:500}"; FAIL=$((FAIL+1)); fi
done

echo; echo "$PASS passed, $FAIL failed"; exit $((FAIL>0))
