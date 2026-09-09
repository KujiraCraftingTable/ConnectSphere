#!/usr/bin/env bash
# Phase 4b: chat group management + meeting-proposal mutation + block-alert.
# Restart connectsphere_backend first (resets its in-memory rate limiter).
#
#   docker restart connectsphere_backend && \
#   ORACLE=http://localhost:3000 PORT=http://localhost:8080 bash server/contract/phase4b.sh
#
# The Swift + Node servers share one Postgres, and one JWT secret, so a token
# minted on either host verifies on both. Group / meeting state is stateful, so
# each flow builds a PARALLEL structure on each host and diffs the normalised
# responses step by step (same shape as phase4.sh's 1:1 flow()).
set -u
ORACLE="${ORACLE:-http://localhost:3000}"; PORT="${PORT:-http://localhost:8080}"
PASS=0; FAIL=0

norm() {
  python3 - "$1" <<'PY'
import sys,json,re
VOL={"id","created_at","updated_at","token","conversation_id","sender_id","message_id","user_id",
     "other_user_id","last_message_at","muted_until","reply_to_message_id","pinned_at","pinned_by",
     "last_message_sender_id","created_by","expires_at","reminder_at","sender_name","joined_at"}
ISO=re.compile(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:?\d\d)$')
UUID=re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
def n(v):
  if isinstance(v,list):
    out=[n(x) for x in v]
    # canonicalise a member list — joined_at ties make ORDER BY joined_at
    # non-deterministic on both servers alike.
    if out and all(isinstance(x,dict) and 'role' in x for x in out):
      out=sorted(out,key=lambda d:json.dumps(d,sort_keys=True))
    return out
  if isinstance(v,dict): return {k:("<v>" if k in VOL else n(v[k])) for k in sorted(v)}
  if isinstance(v,str): return "<ts>" if ISO.match(v) else ("<uuid>" if UUID.match(v) else v)
  return v
try: print(json.dumps(n(json.loads(sys.argv[1])),sort_keys=True))
except Exception: print(json.dumps({"__raw__":sys.argv[1][:400]}))
PY
}

# register once (shared DB) — returns "<token> <userId>"
reg(){ curl -s -X POST "$ORACLE/api/auth/register" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$1\",\"password\":\"password123\"}" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("token",""),d.get("user",{}).get("id",""))'; }

cmp(){ local name="$1" method="$2" path="$3" tok="$4" body="${5:-}" o s
  if [ -n "$body" ]; then
    o=$(curl -s -X "$method" "$ORACLE$path" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "$body")
    s=$(curl -s -X "$method" "$PORT$path"   -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "$body")
  else
    o=$(curl -s -X "$method" "$ORACLE$path" -H "Authorization: Bearer $tok")
    s=$(curl -s -X "$method" "$PORT$path"   -H "Authorization: Bearer $tok")
  fi
  o=$(norm "$o"); s=$(norm "$s")
  if [ "$o" = "$s" ]; then echo "  ok   $name"; PASS=$((PASS+1)); else
    echo "  FAIL $name"; echo "     node :${o:0:460}"; echo "     swift:${s:0:460}"; FAIL=$((FAIL+1)); fi
}

TS="p4b_$(date +%s)_$RANDOM"
read -r TOK_C UID_C < <(reg "${TS}c")
read -r TOK_1 UID_1 < <(reg "${TS}m1")
read -r TOK_2 UID_2 < <(reg "${TS}m2")
read -r TOK_3 UID_3 < <(reg "${TS}m3")
[ -z "$TOK_C" ] || [ -z "$UID_C" ] || [ -z "$UID_1" ] || [ -z "$UID_2" ] || [ -z "$UID_3" ] && { echo "register failed"; exit 2; }
OTHER=$(docker exec connectsphere_db psql -U connectsphere_user -d connectsphere -tAc "SELECT id FROM users WHERE username='duonghung' LIMIT 1;"|tr -d ' \n')
ZERO="00000000-0000-0000-0000-000000000000"
FUT1=$(date -u -v+10d '+%Y-%m-%dT%H:%M:%SZ')
FUT2=$(date -u -v+10d '+%Y-%m-%dT%H:%M:%SZ' | sed 's/T../T14/')  # same day, later hour
FUT3=$(date -u -v+20d '+%Y-%m-%dT%H:%M:%SZ')
PAST=$(date -u -v-2d '+%Y-%m-%dT%H:%M:%SZ')

echo "── stateless validation / 404 ──"
cmp "grp/create-no-members" POST "/api/messages/conversations/group" "$TOK_C" '{"member_ids":[],"mode":"hobby"}'
cmp "grp/create-no-mode"    POST "/api/messages/conversations/group" "$TOK_C" "{\"member_ids\":[\"$UID_1\"]}"
cmp "grp/create-bad-mode"   POST "/api/messages/conversations/group" "$TOK_C" "{\"member_ids\":[\"$UID_1\"],\"mode\":\"x\"}"
cmp "grp/create-dupes"      POST "/api/messages/conversations/group" "$TOK_C" "{\"member_ids\":[\"$UID_1\",\"$UID_1\"],\"mode\":\"hobby\"}"
cmp "grp/create-self"       POST "/api/messages/conversations/group" "$TOK_C" "{\"member_ids\":[\"$UID_C\"],\"mode\":\"hobby\"}"
cmp "grp/settings-404"      PATCH "/api/messages/conversations/$ZERO/settings" "$TOK_C" '{"theme":"x"}'
cmp "grp/members-404"       POST  "/api/messages/conversations/$ZERO/members" "$TOK_C" "{\"member_ids\":[\"$UID_1\"]}"
cmp "grp/remove-404"        DELETE "/api/messages/conversations/$ZERO/members/$UID_1" "$TOK_C"
cmp "grp/promote-404"       POST  "/api/messages/conversations/$ZERO/members/$UID_1/promote" "$TOK_C"
cmp "grp/patch-404"         PATCH "/api/messages/conversations/$ZERO/group" "$TOK_C" '{"name":"x"}'
cmp "grp/leave-404"         POST  "/api/messages/conversations/$ZERO/leave" "$TOK_C"
cmp "grp/blockalert-404"    GET   "/api/messages/conversations/$ZERO/block-alert-state" "$TOK_C"
cmp "grp/blockack-404"      POST  "/api/messages/conversations/$ZERO/block-alert-ack" "$TOK_C"
cmp "mtg/update-404"        PATCH "/api/messages/conversations/$ZERO/messages/$ZERO/meeting-proposal" "$TOK_C" '{"title":"x","starts_at":"'$FUT1'"}'
cmp "mtg/cancel-404"        POST  "/api/messages/conversations/$ZERO/messages/$ZERO/meeting-proposal/cancel" "$TOK_C"
cmp "mtg/respond-404"       POST  "/api/messages/conversations/$ZERO/messages/$ZERO/meeting-response" "$TOK_C" '{"status":"going"}'
cmp "mtg/respond-badstatus" POST  "/api/messages/conversations/$ZERO/messages/$ZERO/meeting-response" "$TOK_C" '{"status":"perhaps"}'

echo "── group flow (parallel groups) ──"
gflow(){ local base="$1"
  local cid
  cid=$(curl -s -X POST "$base/api/messages/conversations/group" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' \
    -d "{\"member_ids\":[\"$UID_1\",\"$UID_2\"],\"mode\":\"hobby\",\"name\":\"Trip\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
  echo "CREATE:"; curl -s -X POST "$base/api/messages/conversations/group" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' \
    -d "{\"member_ids\":[\"$UID_1\",\"$UID_3\"],\"mode\":\"work\",\"name\":\"Squad\"}"; echo
  echo "SETTINGS:"; curl -s "$base/api/messages/conversations/$cid/settings" -H "Authorization: Bearer $TOK_C"; echo
  echo "THEME:";    curl -s -X PATCH "$base/api/messages/conversations/$cid/settings" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' -d '{"theme":"ocean"}'; echo
  echo "NICK:";     curl -s -X PATCH "$base/api/messages/conversations/$cid/settings" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' -d "{\"nickname\":\"Cap\",\"target_user_id\":\"$UID_1\"}"; echo
  echo "RENAME:";   curl -s -X PATCH "$base/api/messages/conversations/$cid/group" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' -d '{"name":"Trip v2"}'; echo
  echo "AVATAR:";   curl -s -X PATCH "$base/api/messages/conversations/$cid/group" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' -d '{"avatar_color":"#334455"}'; echo
  echo "ADD:";      curl -s -X POST "$base/api/messages/conversations/$cid/members" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' -d "{\"member_ids\":[\"$UID_3\"]}"; echo
  echo "ADD-DUP:";  curl -s -X POST "$base/api/messages/conversations/$cid/members" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' -d "{\"member_ids\":[\"$UID_3\"]}"; echo
  echo "REMOVE:";   curl -s -X DELETE "$base/api/messages/conversations/$cid/members/$UID_3" -H "Authorization: Bearer $TOK_C"; echo
  echo "REMOVE-SELF:"; curl -s -X DELETE "$base/api/messages/conversations/$cid/members/$UID_C" -H "Authorization: Bearer $TOK_C"; echo
  echo "BLOCKALERT:"; curl -s "$base/api/messages/conversations/$cid/block-alert-state" -H "Authorization: Bearer $TOK_C"; echo
  echo "BLOCKACK:";  curl -s -X POST "$base/api/messages/conversations/$cid/block-alert-ack" -H "Authorization: Bearer $TOK_C"; echo
  echo "PROMOTE:";  curl -s -X POST "$base/api/messages/conversations/$cid/members/$UID_1/promote" -H "Authorization: Bearer $TOK_C"; echo
  echo "RENAME-NONOWNER:"; curl -s -X PATCH "$base/api/messages/conversations/$cid/group" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' -d '{"name":"nope"}'; echo
  echo "LEAVE:";    curl -s -X POST "$base/api/messages/conversations/$cid/leave" -H "Authorization: Bearer $TOK_C"; echo
}
GN=$(gflow "$ORACLE"); GS=$(gflow "$PORT")
for sec in CREATE SETTINGS THEME NICK RENAME AVATAR ADD ADD-DUP REMOVE REMOVE-SELF BLOCKALERT BLOCKACK PROMOTE RENAME-NONOWNER LEAVE; do
  a=$(echo "$GN"|awk "/^$sec:/{getline;print}"); b=$(echo "$GS"|awk "/^$sec:/{getline;print}")
  na=$(norm "$a"); nb=$(norm "$b")
  if [ "$na" = "$nb" ]; then echo "  ok   gflow/$sec"; PASS=$((PASS+1)); else
    echo "  FAIL gflow/$sec"; echo "     node :${na:0:460}"; echo "     swift:${nb:0:460}"; FAIL=$((FAIL+1)); fi
done

echo "── meeting flow ──"
mflow(){ local base="$1"
  local cid mid gcid gmid
  # 1:1 reminder-only proposal
  cid=$(curl -s -X POST "$base/api/messages/conversations" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' \
    -d "{\"other_user_id\":\"$OTHER\",\"mode\":\"hobby\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
  echo "SEND-PAST:"; curl -s -X POST "$base/api/messages/conversations/$cid/messages" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' \
    -d "{\"message_type\":\"meeting\",\"meeting_proposal\":{\"title\":\"Late\",\"starts_at\":\"$PAST\"}}"; echo
  echo "SEND-NOTITLE:"; curl -s -X POST "$base/api/messages/conversations/$cid/messages" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' \
    -d "{\"message_type\":\"meeting\",\"meeting_proposal\":{\"starts_at\":\"$FUT1\"}}"; echo
  mid=$(curl -s -X POST "$base/api/messages/conversations/$cid/messages" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' \
    -d "{\"message_type\":\"meeting\",\"meeting_proposal\":{\"title\":\"Coffee\",\"location\":\"Cafe\",\"starts_at\":\"$FUT1\",\"ends_at\":\"$FUT2\"}}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
  echo "LIST:";   curl -s "$base/api/messages/conversations/$cid/messages?limit=1" -H "Authorization: Bearer $TOK_C"; echo
  echo "RESCHEDULE:"; curl -s -X PATCH "$base/api/messages/conversations/$cid/messages/$mid/meeting-proposal" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' \
    -d "{\"title\":\"Coffee v2\",\"starts_at\":\"$FUT3\"}"; echo
  echo "RSVP-1TO1:"; curl -s -X POST "$base/api/messages/conversations/$cid/messages/$mid/meeting-response" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' -d '{"status":"going"}'; echo
  echo "CANCEL:"; curl -s -X POST "$base/api/messages/conversations/$cid/messages/$mid/meeting-proposal/cancel" -H "Authorization: Bearer $TOK_C"; echo
  echo "RESCHEDULE-CANCELLED:"; curl -s -X PATCH "$base/api/messages/conversations/$cid/messages/$mid/meeting-proposal" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' \
    -d "{\"title\":\"z\",\"starts_at\":\"$FUT3\"}"; echo
  # group RSVP path
  gcid=$(curl -s -X POST "$base/api/messages/conversations/group" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' \
    -d "{\"member_ids\":[\"$UID_1\",\"$UID_2\"],\"mode\":\"hobby\",\"name\":\"MtgGrp\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
  gmid=$(curl -s -X POST "$base/api/messages/conversations/$gcid/messages" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' \
    -d "{\"message_type\":\"meeting\",\"meeting_proposal\":{\"title\":\"Standup\",\"starts_at\":\"$FUT1\"}}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
  echo "GRSVP:"; curl -s -X POST "$base/api/messages/conversations/$gcid/messages/$gmid/meeting-response" -H "Authorization: Bearer $TOK_1" -H 'Content-Type: application/json' -d '{"status":"maybe"}'; echo
  echo "GRSVP2:"; curl -s -X POST "$base/api/messages/conversations/$gcid/messages/$gmid/meeting-response" -H "Authorization: Bearer $TOK_C" -H 'Content-Type: application/json' -d '{"status":"going"}'; echo
}
MN=$(mflow "$ORACLE"); MS=$(mflow "$PORT")
for sec in SEND-PAST SEND-NOTITLE LIST RESCHEDULE RSVP-1TO1 CANCEL RESCHEDULE-CANCELLED GRSVP GRSVP2; do
  a=$(echo "$MN"|awk "/^$sec:/{getline;print}"); b=$(echo "$MS"|awk "/^$sec:/{getline;print}")
  na=$(norm "$a"); nb=$(norm "$b")
  if [ "$na" = "$nb" ]; then echo "  ok   mflow/$sec"; PASS=$((PASS+1)); else
    echo "  FAIL mflow/$sec"; echo "     node :${na:0:520}"; echo "     swift:${nb:0:520}"; FAIL=$((FAIL+1)); fi
done

echo; echo "$PASS passed, $FAIL failed"; exit $((FAIL>0))
