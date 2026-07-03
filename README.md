# navexra-infra

Self-hosted infrastructure stack: PostgreSQL + Redis, and a personal **LLM
gateway** that exposes your Claude, ChatGPT, and Cursor *subscriptions* as a
single OpenAI-compatible API.

```
                        ┌─────────────────────────────────────┐
   your apps / n8n ───▶ │  litellm :4000  (OpenAI-compatible) │
                        └────┬───────────┬────────────┬───────┘
                             │           │            │
                    ┌────────▼──────┐ ┌──▼──────────┐ ┌▼───────────────┐
                    │ claude-wrapper│ │codex-adapter│ │ cursor-adapter │
                    │     :8000     │ │    :8020    │ │ :8010 (profile)│
                    └────────┬──────┘ └──┬──────────┘ └┬───────────────┘
                     Claude Pro/Max   ChatGPT Plus/Pro  Cursor Individual
                     (OAuth token)    (device login)    (User API key)
                             │
                        ┌────▼─────┐   ┌───────┐
                        │ postgres │   │ redis │      (docker-compose.yml)
                        │  :5432   │   │ :6379 │
                        └──────────┘   └───────┘
```

All ports bind to `127.0.0.1` only. Two compose projects share this repo:
`docker-compose.yml` (databases) and `docker-compose.llm.yml` (gateway,
project name `navexra-llm`).

> **Terms of service.** Driving consumer Claude/ChatGPT subscriptions from a
> server is a gray area — keep usage strictly single-user and low-volume.
> The Cursor path uses an official User API key (fully supported).

---

## 1. Prerequisites

- Docker Engine / Docker Desktop with Compose v2 (`docker compose version`)
- Subscriptions you want to use: Claude Pro/Max, ChatGPT Plus/Pro, Cursor
- For the first Claude token mint: any machine with a browser + Node.js

## 2. Setup

### 2.1 Environment files

```bash
cp .env.example .env            # postgres + redis passwords
cp .env.llm.example .env.llm    # gateway secrets — fill in:
#   LITELLM_MASTER_KEY      openssl rand -hex 32   (keep the sk- prefix)
#   LITELLM_SALT_KEY        openssl rand -hex 32   (must stay stable forever)
#   LLM_DB_PASSWORD         openssl rand -hex 18
#   CLAUDE_WRAPPER_API_KEY  openssl rand -hex 24   (internal bearer)
#   CODEX_ADAPTER_API_KEY   openssl rand -hex 24   (internal bearer)
#   CURSOR_ADAPTER_API_KEY  openssl rand -hex 24   (internal bearer)
```

Never commit `.env` / `.env.llm` (already gitignored).

### 2.2 Databases

```bash
docker compose up -d
./scripts/bootstrap-db.sh
```

Creates (idempotently): `litellm` DB for the gateway, and `merchant_api` for
your app → `DATABASE_URL=postgresql://merchant:merchant@localhost:5432/merchant_api`
(change this password before exposing anything beyond localhost).

**Already have postgres/redis/n8n running?** Skip `docker compose up -d` —
the gateway reuses the same Postgres instance, only *adding* the two
databases above (existing DBs like `n8n` are untouched). Requirements:
the container is named `postgres` and sits on the `infra_db_net` network
(verify: `docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' postgres`).
Run `./scripts/bootstrap-db.sh`; if it can't find the compose service
(container started from another project), create the roles/DBs directly:

```bash
docker exec -i postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres' <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='litellm') THEN
    CREATE ROLE litellm LOGIN PASSWORD '<LLM_DB_PASSWORD from .env.llm>';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='merchant') THEN
    CREATE ROLE merchant LOGIN PASSWORD 'merchant';
  END IF;
END $$;
SQL
docker exec postgres sh -c 'psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='"'"'litellm'"'"'" | grep -q 1 || psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE litellm OWNER litellm"'
docker exec postgres sh -c 'psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='"'"'merchant_api'"'"'" | grep -q 1 || psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE merchant_api OWNER merchant"'
```

### 2.3 Claude login (one-time, needs a browser)

```bash
npm i -g @anthropic-ai/claude-code
claude setup-token
# paste the printed sk-ant-oat01-... into .env.llm as CLAUDE_CODE_OAUTH_TOKEN
```

Token is valid ~1 year — set a rotation reminder.

### 2.4 Start the gateway

```bash
docker compose -f docker-compose.llm.yml --env-file .env.llm --profile cursor up -d --build
```

Omit `--profile cursor` if you don't use Cursor. Never pass
`--remove-orphans` to either compose command (the two stacks share this
directory).

### 2.5 ChatGPT login (one-time, works headless)

```bash
docker compose -f docker-compose.llm.yml --env-file .env.llm \
  run --rm codex-adapter codex login --device-auth
# open the printed URL on any device, enter the code, sign in with ChatGPT
```

Credentials persist in the `codex_config` docker volume and auto-refresh.
**They do not transfer between machines** — redo this step on the VPS.

### 2.6 Cursor key (optional, one-time)

Mint a *User API key* at [cursor.com/dashboard](https://cursor.com/dashboard)
→ Integrations → API Keys, put it in `.env.llm` as `CURSOR_API_KEY`, then
restart the adapter.

## 3. Test

```bash
./scripts/smoke-test.sh
```

Checks DBs, all backend healths, and runs a real completion through every
configured subscription. All green = ready.

## 4. Using the API

One OpenAI-compatible endpoint: `http://localhost:4000/v1`. Switch backends
by model name:

| model | backend |
|---|---|
| `claude-sonnet` / `claude-opus` / `claude-haiku` | Claude subscription |
| `chatgpt` / `gpt-codex` | ChatGPT subscription |
| `cursor-composer` | Cursor subscription (agentic coding) |

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet","messages":[{"role":"user","content":"Hi"}]}'
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:4000/v1", api_key="<key>")
r = client.chat.completions.create(model="chatgpt",
        messages=[{"role": "user", "content": "Hi"}])
print(r.choices[0].message.content)
```

**Keys.** Use `LITELLM_MASTER_KEY` only for admin/testing. For apps, mint
limited *virtual keys* (per-app models, rate limits, expiry, revocation):

```bash
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer <master-key>" -H "Content-Type: application/json" \
  -d '{"key_alias":"my-app","models":["claude-sonnet","chatgpt"],"duration":"90d"}'
```

Admin UI: `http://localhost:4000/ui` (log in with the master key).

From other containers on the `infra_db_net` network (e.g. n8n), use
`http://litellm:4000/v1` as the base URL.

**Adding / pinning models.** Edit `llm/litellm-config.yaml` (e.g. add an
entry with `model: openai/claude-opus-4-5-20250929` or pin a GPT model),
then `docker compose -f docker-compose.llm.yml --env-file .env.llm restart litellm`.
The Claude wrapper's live model list: `curl -H "Authorization: Bearer $CLAUDE_WRAPPER_API_KEY" http://127.0.0.1:8000/v1/models`.

## 5. Day-to-day operations

```bash
# status / logs
docker compose -f docker-compose.llm.yml --env-file .env.llm --profile cursor ps
docker logs litellm --tail 40        # likewise: claude-wrapper, codex-adapter, cursor-adapter

# restart after config change (bind-mounted config is NOT auto-reloaded)
docker compose -f docker-compose.llm.yml --env-file .env.llm restart litellm

# rebuild after adapter code change (--force-recreate ensures the new image is used)
docker compose -f docker-compose.llm.yml --env-file .env.llm --profile cursor \
  up -d --build --force-recreate cursor-adapter

# stop the gateway (DBs keep running)
docker compose -f docker-compose.llm.yml --env-file .env.llm --profile cursor down
```

## 6. VPS deployment

Identical to local, plus:

1. Copy `.env` and `.env.llm` to the VPS manually (gitignored; the Claude
   token and Cursor key travel inside `.env.llm`).
2. If postgres/redis/n8n already run there, follow the "already have
   postgres" path in section 2.2 — same instance, new databases only.
3. Run sections 2.4 and 2.5 (ChatGPT device login must be redone per
   machine — it lives in a local docker volume), then `./scripts/smoke-test.sh`.
4. Public TLS: point DNS at the VPS and configure host nginx to proxy
   `llm.infra.<domain>` → `127.0.0.1:4000` — see `docs/ADD_LLM.md`.
5. Give apps virtual keys, never the master key. n8n on the same network
   can use `http://litellm:4000/v1` directly.

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `postgres` restart-loop: "initialized by PostgreSQL version N" | Old data volume from a different major. Wipe it (`docker volume rm navexra-infra_postgres_data`) or pin the old image version. |
| `litellm` exit code 137 | OOM-killed — memory limit too low (needs ~1 GB at startup). |
| `litellm` "Invalid model name" after config edit | Container didn't reload the bind-mounted config — `restart litellm`. |
| Adapter code changes not taking effect | Container still on the old image — rebuild with `--force-recreate`. |
| `codex-adapter` 503 "not logged in" | Run the device login (section 2.5). |
| `cursor-adapter` "Workspace Trust Required" | The adapter passes `--trust`; rebuild if you see this (old image). |
| Claude 401 via gateway | Token expired/revoked or truncated — re-mint with `claude setup-token`, verify with `CLAUDE_CODE_OAUTH_TOKEN=<t> claude -p "say ok"`. |
| Health shows `unhealthy` but service answers | Healthcheck binary missing in image — healthchecks here use curl/python for that reason. |

## 8. Repo map

```
docker-compose.yml        postgres + redis (project: navexra-infra)
docker-compose.llm.yml    litellm + claude-wrapper + codex-adapter (+cursor, +ollama) (project: navexra-llm)
docker-compose.n8n.yml    n8n automation (see docs/ADD_N8N.md)
llm/litellm-config.yaml   model routing table
llm/codex-adapter/        ChatGPT-subscription adapter (FastAPI + Codex CLI)
llm/cursor-adapter/       Cursor-subscription adapter (FastAPI + cursor-agent)
scripts/bootstrap-db.sh   create litellm + merchant_api DBs (idempotent)
scripts/smoke-test.sh     end-to-end health + real completion tests
docs/                     ADD_LLM.md, ADD_CHATGPT.md, ADD_N8N.md, ADD_NGINX.md
```
