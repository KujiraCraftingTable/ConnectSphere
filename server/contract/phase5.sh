#!/usr/bin/env bash
# Phase 5 — AI search core. Needs Ollama running (qwen2.5 + mxbai-embed-large)
# and user_embedding_chunks populated. Asserts RESULT-SET OVERLAP (not exact
# order) vs the Node oracle, plus exact response-shape parity.
#
#   docker restart connectsphere_backend && \
#   ORACLE=http://localhost:3000 PORT=http://localhost:8080 bash server/contract/phase5.sh
set -u
ORACLE="${ORACLE:-http://localhost:3000}"; PORT="${PORT:-http://localhost:8080}"
PASS=0; FAIL=0
TS="p5_$(date +%s)_$RANDOM"
TOK=$(curl -s -X POST "$ORACLE/api/auth/register" -H 'Content-Type: application/json' \
  -d "{\"username\":\"${TS}\",\"password\":\"password123\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
[ -z "$TOK" ] && { echo "register failed"; exit 2; }

ai(){ curl -s -X POST "$1/api/search/ai" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d "$2"; }
an(){ curl -s -X POST "$1/api/posts/analyze" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d "$2"; }

check_ai(){ # name, body, min-overlap%
  local n s
  n=$(ai "$ORACLE" "$2"); s=$(ai "$PORT" "$2")
  python3 - "$1" "$n" "$s" "$3" <<'PY'
import sys,json
name,n,s,minov=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4])
try: n=json.loads(n); s=json.loads(s)
except Exception: print(f"  FAIL {name} (non-JSON)"); sys.exit(1)
if "data" not in n or "data" not in s: print(f"  FAIL {name} (no data)"); sys.exit(1)
ni=[u["id"] for u in n["data"]]; si=[u["id"] for u in s["data"]]
uni=len(set(ni)|set(si)) or 1; ov=100*len(set(ni)&set(si))//uni
ckmatch = sorted(n.get("criteria",{}).keys()) == sorted(s.get("criteria",{}).keys())
ukmatch = (not ni or not si) or (sorted(n["data"][0].keys()) == sorted(s["data"][0].keys()))
ok = ov >= minov and ckmatch and ukmatch
print(f"  {'ok  ' if ok else 'FAIL'} {name}  overlap={ov}% (n={len(ni)},s={len(si)}) criteria_keys={ckmatch} user_keys={ukmatch}")
sys.exit(0 if ok else 1)
PY
}
check_an(){ # name, body
  local n s
  n=$(an "$ORACLE" "$2"); s=$(an "$PORT" "$2")
  python3 - "$1" "$n" "$s" <<'PY'
import sys,json
name,n,s=sys.argv[1],json.loads(sys.argv[2]),json.loads(sys.argv[3])
for k in ("reason",): n.pop(k,None); s.pop(k,None)
ok = json.dumps(n,sort_keys=True)==json.dumps(s,sort_keys=True)
print(f"  {'ok  ' if ok else 'FAIL'} {name}  node={json.dumps(n,sort_keys=True)} swift={json.dumps(s,sort_keys=True)}")
sys.exit(0 if ok else 1)
PY
}

for c in \
  'ai/anime|{"query":"tìm bạn thích anime","mode":"hobby"}|80' \
  'ai/dev|{"query":"find iOS developer who knows React","mode":"work"}|75' \
  'ai/empty|{"query":"asdfqwerzxcv nonsense tokens","mode":"hobby"}|0' ; do
  IFS='|' read -r name body ov <<< "$c"
  if check_ai "$name" "$body" "$ov"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
done
n=$(ai "$ORACLE" '{"query":""}'); s=$(ai "$PORT" '{"query":""}')
python3 -c 'import sys,json;sys.exit(0 if json.loads(sys.argv[1])==json.loads(sys.argv[2]) else 1)' "$n" "$s" \
  && { echo "  ok   ai/query-required"; PASS=$((PASS+1)); } || { echo "  FAIL ai/query-required  n=$n s=$s"; FAIL=$((FAIL+1)); }

for c in \
  'analyze/fast-work|{"content":"Sprint xong, deploy code review merge PR, standup với team","currentMode":"hobby"}' \
  'analyze/fast-hobby|{"content":"đi cafe trà sữa với bạn bè cuối tuần xem anime","currentMode":"work"}' \
  'analyze/empty|{"content":""}' ; do
  IFS='|' read -r name body <<< "$c"
  if check_an "$name" "$body"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
done

# suggestions: no-mode path is static on both; mode path is a Phase-8 divergence (LLM cache)
n=$(curl -s "$ORACLE/api/search/suggestions" -H "Authorization: Bearer $TOK")
s=$(curl -s "$PORT/api/search/suggestions" -H "Authorization: Bearer $TOK")
[ "$n" = "$s" ] && { echo "  ok   suggestions/nomode"; PASS=$((PASS+1)); } || { echo "  FAIL suggestions/nomode"; FAIL=$((FAIL+1)); }

echo; echo "$PASS passed, $FAIL failed"; exit $((FAIL>0))
