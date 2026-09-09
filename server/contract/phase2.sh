#!/usr/bin/env bash
# Phase 2 contract check. Restart connectsphere_backend first (rate limiter).
set -u
ORACLE="${ORACLE:-http://localhost:3000}"
PORT="${PORT:-http://localhost:8080}"
PASS=0; FAIL=0

norm() {
  python3 - "$1" <<'PY'
import sys, json, re
VOL = {"token","id","created_at","updated_at","iat","exp","pinned_at","expires_at","viewed_at","deleted_at",
       "shared_post_id","post_id","parent_comment_id","score","semantic","recency","engagement","nextCursor","starts_at","ends_at","author_id","commentId"}
ISO = re.compile(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:?\d\d)$')
def canon(s):
    return "<ts>" if ISO.match(s) else s
def n(v):
    if isinstance(v, list): return [n(x) for x in v]
    if isinstance(v, dict): return {k: ("<v>" if k in VOL else n(v[k])) for k in sorted(v)}
    if isinstance(v, str): return canon(v)
    return v
try: print(json.dumps(n(json.loads(sys.argv[1])), sort_keys=True))
except Exception: print(json.dumps({"__raw__": sys.argv[1][:300]}))
PY
}
mk() { curl -s -X POST "$1/api/auth/register" -H 'Content-Type: application/json' -d "{\"username\":\"$2\",\"password\":\"password123\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))'; }

cmp() { # name method path token_n token_s [body]
  local name="$1" method="$2" path="$3" tn="$4" ts="$5" body="${6:-}" o s
  if [ -n "$body" ]; then
    o=$(curl -s -X "$method" "$ORACLE$path" -H "Authorization: Bearer $tn" -H 'Content-Type: application/json' -d "$body")
    s=$(curl -s -X "$method" "$PORT$path"   -H "Authorization: Bearer $ts" -H 'Content-Type: application/json' -d "$body")
  else
    o=$(curl -s -X "$method" "$ORACLE$path" -H "Authorization: Bearer $tn")
    s=$(curl -s -X "$method" "$PORT$path"   -H "Authorization: Bearer $ts")
  fi
  o=$(norm "$o"); s=$(norm "$s")
  if [ "$o" = "$s" ]; then echo "  ok   $name"; PASS=$((PASS+1)); else
    echo "  FAIL $name"; echo "     node: ${o:0:400}"; echo "     swift:${s:0:400}"; FAIL=$((FAIL+1)); fi
}

TS="p2_$(date +%s)_$RANDOM"
TN=$(mk "$ORACLE" "${TS}n"); TSK=$(mk "$PORT" "${TS}s")
[ -z "$TN" ] || [ -z "$TSK" ] && { echo "register failed — restart connectsphere_backend"; exit 2; }
# setup both so they can post in a mode
for pair in "$ORACLE $TN ${TS}n" "$PORT $TSK ${TS}s"; do set -- $pair
  curl -s -X POST "$1/api/auth/setup" -H "Authorization: Bearer $2" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$3\",\"display_name\":\"P2 Tester\",\"dob\":\"1990-01-01\",\"location\":\"Ha Noi\",\"default_mode\":\"hobby\"}" >/dev/null
done

cmp "posts/list"        GET "/api/posts?limit=3" "$TN" "$TSK"
cmp "posts/list-work"   GET "/api/posts?limit=3&mode=work" "$TN" "$TSK"
cmp "posts/list-tag"    GET "/api/posts?limit=3&tag=nonexistenttag123" "$TN" "$TSK"
cmp "posts/deleted"     GET "/api/posts/deleted" "$TN" "$TSK"
cmp "posts/saved"       GET "/api/posts/saved" "$TN" "$TSK"
cmp "posts/comments-deleted" GET "/api/posts/comments/deleted" "$TN" "$TSK"
cmp "posts/get-missing" GET "/api/posts/00000000-0000-0000-0000-000000000000" "$TN" "$TSK"
cmp "posts/create-badmode" POST "/api/posts" "$TN" "$TSK" '{"content":"hi","mode":"nope"}'
cmp "posts/create-empty" POST "/api/posts" "$TN" "$TSK" '{"mode":"hobby"}'
cmp "posts/create-poll-1opt" POST "/api/posts" "$TN" "$TSK" '{"content":"q","mode":"hobby","post_type":"poll","options":["a"]}'
cmp "posts/create-event-notitle" POST "/api/posts" "$TN" "$TSK" '{"content":"e","mode":"hobby","post_type":"event","eventData":{"startsAt":"2030-01-01T00:00:00Z"}}'
cmp "feed/rec-badmode"  GET "/api/feed/recommendations" "$TN" "$TSK"
cmp "feed/rec"          GET "/api/feed/recommendations?mode=hobby&limit=3" "$TN" "$TSK"
cmp "tags/trending"     GET "/api/tags/trending?limit=5" "$TN" "$TSK"
cmp "tags/suggest-noprefix" GET "/api/tags/suggest" "$TN" "$TSK"
cmp "tags/suggest"      GET "/api/tags/suggest?prefix=a&limit=5" "$TN" "$TSK"
cmp "stories/list"      GET "/api/stories" "$TN" "$TSK"
cmp "stories/create-nourl" POST "/api/stories" "$TN" "$TSK" '{}'
cmp "events/rsvp-badstatus" POST "/api/events/00000000-0000-0000-0000-000000000000/rsvp" "$TN" "$TSK" '{"status":"zzz"}'
cmp "events/rsvp-missing" POST "/api/events/00000000-0000-0000-0000-000000000000/rsvp" "$TN" "$TSK" '{"status":"going"}'
cmp "linkpreview-nourl" POST "/api/link-preview" "$TN" "$TSK" '{}'
cmp "linkpreview-blocked" POST "/api/link-preview" "$TN" "$TSK" '{"url":"http://localhost/x"}'

# stateful: create a text post on each, list it back, comment, like, save, hide, delete
flow() {
  local base="$1" tok="$2"
  local pid
  pid=$(curl -s -X POST "$base/api/posts" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d '{"content":"phase2 flow post #flowtag","mode":"hobby","hashtags":["flowtag"]}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
  curl -s -X POST "$base/api/posts/$pid/comments" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"content":"nice"}' >/dev/null
  curl -s -X POST "$base/api/posts/$pid/like" -H "Authorization: Bearer $tok" >/dev/null
  curl -s -X POST "$base/api/posts/$pid/save" -H "Authorization: Bearer $tok" >/dev/null
  # read the post + its comments
  echo "POST:"; curl -s "$base/api/posts/$pid" -H "Authorization: Bearer $tok"; echo
  echo "COMMENTS:"; curl -s "$base/api/posts/$pid/comments" -H "Authorization: Bearer $tok"; echo
  echo "SAVED:"; curl -s "$base/api/posts/saved" -H "Authorization: Bearer $tok"; echo
}
FO=$(flow "$ORACLE" "$TN"); FS=$(flow "$PORT" "$TSK")
fo=$(norm "$(echo "$FO" | tr -d '\n' | python3 -c 'import sys;print(sys.stdin.read())' 2>/dev/null || echo "$FO")")
# compare piecewise by section
for sec in POST COMMENTS SAVED; do
  a=$(echo "$FO" | awk "/^$sec:/{getline; print}" | sed "s/${TS}n/<u>/g")
  b=$(echo "$FS" | awk "/^$sec:/{getline; print}" | sed "s/${TS}s/<u>/g")
  na=$(norm "$a"); nb=$(norm "$b")
  if [ "$na" = "$nb" ]; then echo "  ok   flow/$sec"; PASS=$((PASS+1)); else
    echo "  FAIL flow/$sec"; echo "     node: ${na:0:500}"; echo "     swift:${nb:0:500}"; FAIL=$((FAIL+1)); fi
done

echo
echo "$PASS passed, $FAIL failed"
exit $((FAIL>0))
