#!/usr/bin/env bash
# End-to-end smoke test for the LLM gateway stack. Run from the repo root on
# the machine running docker:
#   ./scripts/smoke-test.sh
# Exits non-zero on the first hard failure; prints WARN for soft issues.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
hdr()  { echo; echo "== $1 =="; }

[ -f .env.llm ] || { echo "ERROR: .env.llm not found"; exit 1; }
MASTER_KEY="$(grep -E '^LITELLM_MASTER_KEY=' .env.llm | cut -d= -f2-)"
CLAUDE_KEY="$(grep -E '^CLAUDE_WRAPPER_API_KEY=' .env.llm | cut -d= -f2-)"
CODEX_KEY="$(grep -E '^CODEX_ADAPTER_API_KEY=' .env.llm | cut -d= -f2-)"

hdr "Containers"
docker compose ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null
docker compose -f docker-compose.llm.yml --env-file .env.llm ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null

hdr "Postgres (litellm DB)"
LLM_DB_USER="$(grep -E '^LLM_DB_USER=' .env.llm | cut -d= -f2-)"
LLM_DB_PASSWORD="$(grep -E '^LLM_DB_PASSWORD=' .env.llm | cut -d= -f2-)"
LLM_DB_NAME="$(grep -E '^LLM_DB_NAME=' .env.llm | cut -d= -f2-)"
if docker compose exec -T -e PGPASSWORD="$LLM_DB_PASSWORD" postgres \
     psql -h 127.0.0.1 -U "$LLM_DB_USER" -d "$LLM_DB_NAME" -tAc 'SELECT 1' 2>/dev/null | grep -q 1; then
  ok "litellm can connect to $LLM_DB_NAME"
else
  bad "litellm DB connection (run ./scripts/bootstrap-db.sh)"
fi
# App DB (merchant_api) is managed outside bootstrap-db.sh — soft check only.
if docker compose exec -T -e PGPASSWORD=merchant postgres \
     psql -h 127.0.0.1 -U merchant -d merchant_api -tAc 'SELECT 1' 2>/dev/null | grep -q 1; then
  ok "merchant can connect to merchant_api"
else
  echo "  SKIP  merchant_api not present (create it if your app needs it)"
fi

hdr "claude-wrapper (127.0.0.1:8000)"
if curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then
  ok "health endpoint"
  echo "  models advertised by the wrapper:"
  curl -fsS -H "Authorization: Bearer $CLAUDE_KEY" http://127.0.0.1:8000/v1/models 2>/dev/null \
    | python3 -c 'import json,sys; [print("   -", m["id"]) for m in json.load(sys.stdin).get("data",[])]' \
    || echo "   (could not list models — check CLAUDE_WRAPPER_API_KEY)"
else
  bad "claude-wrapper /health not responding"
fi

hdr "codex-adapter (127.0.0.1:8020)"
CODEX_HEALTH="$(curl -fsS http://127.0.0.1:8020/health 2>/dev/null)"
if [ -n "$CODEX_HEALTH" ]; then
  ok "health endpoint: $CODEX_HEALTH"
  echo "$CODEX_HEALTH" | grep -q '"logged_in": *true' \
    || echo "  WARN: codex not logged in yet — run:"
  echo "$CODEX_HEALTH" | grep -q '"logged_in": *true' \
    || echo "        docker compose -f docker-compose.llm.yml --env-file .env.llm run --rm codex-adapter codex login --device-auth"
else
  bad "codex-adapter /health not responding"
fi

hdr "LiteLLM (127.0.0.1:4000)"
# LiteLLM needs ~30-60s on first boot (Prisma migrations); poll up to 120s.
ALIVE=0
for i in $(seq 1 60); do
  if curl -fsS -m 3 http://127.0.0.1:4000/health/liveliness 2>/dev/null | grep -qi alive; then
    ALIVE=1; break
  fi
  sleep 2
done
if [ "$ALIVE" = 1 ]; then
  ok "liveliness (after ~$((i*2))s)"
else
  bad "litellm not alive after 120s (check: docker logs litellm --tail 40)"
fi

chat() { # $1=model  $2=label
  echo "  -> chat completion via litellm: model=$1"
  RESP="$(curl -sS -m 300 http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer $MASTER_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}]}")"
  if echo "$RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"])' 2>/dev/null; then
    ok "$2 answered"
  else
    bad "$2 — response: $(echo "$RESP" | head -c 400)"
  fi
}

hdr "Claude via gateway"
chat "claude-sonnet" "Claude (subscription)"

hdr "ChatGPT via gateway"
chat "chatgpt" "ChatGPT/Codex (subscription)"

# Cursor is optional (profile: cursor) — only test if the adapter is running.
if curl -fsS -m 3 http://127.0.0.1:8010/health >/dev/null 2>&1; then
  hdr "Cursor via gateway"
  chat "cursor-composer" "Cursor (subscription)"
else
  echo
  echo "== Cursor adapter not running — skipped (enable with --profile cursor) =="
fi

echo
echo "== Result: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
