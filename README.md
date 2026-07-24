# navexra-infra

Self-hosted infrastructure stack: PostgreSQL + Redis + MongoDB (single-node
replica set), and a personal **LLM gateway** that exposes your Claude,
ChatGPT, and Cursor *subscriptions* as a single OpenAI-compatible API.

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
`docker-compose.yml` (databases — Postgres, Redis, MongoDB) and
`docker-compose.llm.yml` (gateway, project name `navexra-llm`).

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

Creates (idempotently) the `litellm` role + DB for the gateway, using the
credentials in `.env.llm`. Re-running is safe — it re-asserts the password
from `.env.llm`, so rotating is: edit the file, re-run, restart litellm.

App databases (e.g. `merchant_api`) are managed separately — create them
with the direct `docker exec` SQL below or your own migrations.

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

One OpenAI-compatible endpoint. Pick the base URL for where you're calling
from:

| calling from                                    | base URL                             |
| ----------------------------------------------- | ------------------------------------ |
| anywhere on the internet (production)           | `https://llm.infra.navexra.com/v1`   |
| the VPS itself / local machine                  | `http://localhost:4000/v1`           |
| containers on `infra_db_net` (e.g. n8n)         | `http://litellm:4000/v1`             |

Switch backends by model name:

| model                                            | backend                              |
| ------------------------------------------------ | ------------------------------------ |
| `claude-sonnet` / `claude-opus` / `claude-haiku` | Claude subscription                  |
| `chatgpt` / `gpt-codex`                          | ChatGPT subscription                 |
| `cursor-composer`                                | Cursor subscription (agentic coding) |

```bash
curl https://llm.infra.navexra.com/v1/chat/completions \
  -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet","messages":[{"role":"user","content":"Hi"}]}'
```

```python
from openai import OpenAI
client = OpenAI(base_url="https://llm.infra.navexra.com/v1", api_key="<key>")
r = client.chat.completions.create(model="chatgpt",
        messages=[{"role": "user", "content": "Hi"}])
print(r.choices[0].message.content)
```

**Keys.** Use `LITELLM_MASTER_KEY` only for admin/testing. For apps, mint
limited *virtual keys* (per-app models, rate limits, expiry, revocation):

```bash
curl -X POST https://llm.infra.navexra.com/key/generate \
  -H "Authorization: Bearer <master-key>" -H "Content-Type: application/json" \
  -d '{"key_alias":"my-app","models":["claude-sonnet","chatgpt"],"duration":"90d"}'
```

Admin UI: `https://llm.infra.navexra.com/ui` (log in with the master key).

In n8n, set the OpenAI credential's Base URL to `http://litellm:4000/v1`
(same docker network) with a virtual key.

**Full API reference** — every endpoint, streaming, key management, error
codes: [docs/API_USAGE.md](docs/API_USAGE.md).

**Adding / pinning models.** Edit `llm/litellm-config.yaml` (e.g. add an
entry with `model: openai/claude-opus-4-5-20250929` or pin a GPT model),
then `docker compose -f docker-compose.llm.yml --env-file .env.llm restart litellm`.
The Claude wrapper's live model list: `curl -H "Authorization: Bearer $CLAUDE_WRAPPER_API_KEY" http://127.0.0.1:8000/v1/models`.

## [lm.infra.navexra.com](http://lm.infra.navexra.com)5. Day-to-day operations

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
4. Public TLS: see section 6.1 below.
5. Give apps virtual keys, never the master key. n8n on the same network
  can use `http://litellm:4000/v1` directly.

### 6.1 Public HTTPS via host nginx + certbot

1. **DNS**: add an A/AAAA record for `llm.infra.navexra.com` with the same
  values as your other subdomains (`dig +short n8n.infra.navexra.com A AAAA`).
   Wait until `dig +short llm.infra.navexra.com` answers.
2. **Bootstrap vhost** (HTTP only; certbot adds TLS):
  ```bash
   cat > /etc/nginx/sites-available/llm.infra.navexra.com <<'EOF'
   server {
       listen 80;
       listen [::]:80;
       server_name llm.infra.navexra.com;
       location /.well-known/acme-challenge/ { root /var/www/certbot; }
       location / { return 301 https://$host$request_uri; }
   }
   EOF
   ln -s /etc/nginx/sites-available/llm.infra.navexra.com /etc/nginx/sites-enabled/
   nginx -t && systemctl reload nginx
   certbot --nginx -d llm.infra.navexra.com
  ```
3. **Fix the 443 block.** Certbot reuses the port-80 block, leaving the
  HTTPS server with `location / { return 301 ... }` — an infinite redirect
   loop. In the 443 server block, replace that `location /` with the proxy
   (keep all `# managed by Certbot` lines), and keep the ACME location in
   the port-80 block for renewals:
4. **Verify**:
  ```bash
   nginx -t && systemctl reload nginx
   curl https://llm.infra.navexra.com/health/liveliness   # → "I'm alive!"
  ```

Apps then use `https://llm.infra.navexra.com/v1` as the OpenAI base URL with a
virtual key. This also exposes the admin UI at `/ui` (protected by the
master key login) — restrict it by IP in nginx if you prefer.

## 7. Troubleshooting


| Symptom                                                        | Cause / fix                                                                                                                           |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `postgres` restart-loop: "initialized by PostgreSQL version N" | Old data volume from a different major. Wipe it (`docker volume rm navexra-infra_postgres_data`) or pin the old image version.        |
| `litellm` exit code 137                                        | OOM-killed — memory limit too low (needs ~1 GB at startup).                                                                           |
| `litellm` "Invalid model name" after config edit               | Container didn't reload the bind-mounted config — `restart litellm`.                                                                  |
| Adapter code changes not taking effect                         | Container still on the old image — rebuild with `--force-recreate`.                                                                   |
| `codex-adapter` 503 "not logged in"                            | Run the device login (section 2.5).                                                                                                   |
| `cursor-adapter` "Workspace Trust Required"                    | The adapter passes `--trust`; rebuild if you see this (old image).                                                                    |
| Claude 401 via gateway                                         | Token expired/revoked or truncated — re-mint with `claude setup-token`, verify with `CLAUDE_CODE_OAUTH_TOKEN=<t> claude -p "say ok"`. |
| Health shows `unhealthy` but service answers                   | Healthcheck binary missing in image — healthchecks here use curl/python for that reason.                                              |


## 8. Repo map

```
docker-compose.yml        postgres + redis + mongodb (project: navexra-infra)
docker-compose.llm.yml    litellm + claude-wrapper + codex-adapter (+cursor, +ollama) (project: navexra-llm)
docker-compose.n8n.yml    n8n automation (see docs/ADD_N8N.md)
llm/litellm-config.yaml   model routing table
llm/codex-adapter/        ChatGPT-subscription adapter (FastAPI + Codex CLI)
llm/cursor-adapter/       Cursor-subscription adapter (FastAPI + cursor-agent)
scripts/bootstrap-db.sh   create litellm + merchant_api DBs (idempotent)
scripts/smoke-test.sh     end-to-end health + real completion tests
docs/                     ADD_LLM.md, ADD_CHATGPT.md, ADD_N8N.md, ADD_NGINX.md
```

---

## 9. MongoDB single-node replica set — setup reference

One-time setup after `docker compose up`. Needed so MongoDB transactions work
(permanent fix for *“transaction numbers are only allowed on a replica set
member”*). Keep this section for reference after the first successful initiate.

### Why this is needed

- MongoDB transactions only work on a replica set, not on standalone.
- We do not need redundancy — only transactions — so we run a **single-node**
  replica set (one member that is its own primary).
- With replica set + auth enabled, MongoDB requires an internal **keyFile**
  even for a single node.

### One-time prerequisites (first time only)

#### 1. Create the keyfile

Compose mounts files; it cannot create the keyfile. Run once on the host:

```bash
mkdir -p /root/scripts/mongo
openssl rand -base64 756 > /root/scripts/mongo/keyfile
chmod 400 /root/scripts/mongo/keyfile
chown 999:999 /root/scripts/mongo/keyfile
```

`999` is the `mongodb` user UID inside the container. Wrong owner or looser
permissions will prevent Mongo from starting.

#### 2. Compose service (already in `docker-compose.yml`)

Key pieces: keyfile volume mount, `dokploy-network`, and `mongod` in replica-set mode:

```yaml
mongodb:
  image: mongo:8.0.26
  container_name: mongodb
  restart: unless-stopped
  networks:
    - db_net
    - dokploy-network            # required if apps on Dokploy need Mongo
  ports:
    - "127.0.0.1:27017:27017"
  volumes:
    - mongo_data:/data/db
    - /root/scripts/mongo/keyfile:/etc/mongo-keyfile:ro
  environment:
    MONGO_INITDB_ROOT_USERNAME: ${MONGO_USER:?...}
    MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASSWORD:?...}
    MONGO_INITDB_DATABASE: ${MONGO_DB:?...}
  command:
    - mongod
    - --replSet
    - rs0
    - --keyFile
    - /etc/mongo-keyfile
    - --bind_ip_all
    - --wiredTigerCacheSizeGB
    - "1.0"
```

### Steps after `docker compose up` (every fresh setup)

#### Step 1 — Start the container

```bash
cd /root/infra/navexra-infra        # where the compose file lives
docker compose up -d mongodb
docker logs mongodb --tail 20
```

**Expect:** container healthy. Logs may show *“No primary exists currently”*
and *“oplog.rs not found”* — normal until initiate (Step 3).

If you see a keyfile permission error:

```bash
chmod 400 /root/scripts/mongo/keyfile
chown 999:999 /root/scripts/mongo/keyfile
docker compose up -d --force-recreate mongodb
```

#### Step 2 — Load credentials into the shell

```bash
export MONGO_USER=$(docker exec mongodb printenv MONGO_INITDB_ROOT_USERNAME)
export MONGO_PASSWORD=$(docker exec mongodb printenv MONGO_INITDB_ROOT_PASSWORD)
```

If `${MONGO_USER}` is empty, auth fails (`Command replSetInitiate requires
authentication`). Always export these, or paste the values directly.

#### Step 3 — Initiate the replica set (enables transactions)

```bash
docker exec -it mongodb mongosh -u "$MONGO_USER" -p "$MONGO_PASSWORD" \
  --authenticationDatabase admin \
  --eval 'rs.initiate({_id:"rs0", members:[{_id:0, host:"mongodb:27017"}]})'
```

**Expect:** `{ ok: 1 }`.

Use host `mongodb:27017` — **not** `localhost`. That hostname is what the
replica set advertises and what apps resolve.

#### Step 4 — Confirm primary

```bash
sleep 5
docker exec mongodb mongosh -u "$MONGO_USER" -p "$MONGO_PASSWORD" \
  --authenticationDatabase admin --quiet --eval 'rs.status().myState'
```

**Expect:** `1` (PRIMARY). Then check logs — *oplog.rs not found* should be gone:

```bash
docker logs mongodb --tail 15
```

#### Step 5 — Attach to `dokploy-network` (if the app runs on Dokploy)

Otherwise the app cannot resolve hostname `mongodb` (Mongoose
*Unable to connect… Retrying* / `getaddrinfo ENOTFOUND`).

```bash
docker network connect dokploy-network mongodb 2>/dev/null || true
docker inspect mongodb \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
```

**Expect:** both `db_net` and `dokploy-network`.

`docker network connect` survives reboot/stop-start, but is lost after
`docker compose down && up`. Prefer listing `- dokploy-network` in compose
(already done in this repo).

#### Step 6 — App connection string

In the Dokploy service Environment tab:

```text
MONGODB_URL=mongodb://<USER>:<PASS>@mongodb:27017/<dbname>?authSource=admin&replicaSet=rs0
```

Required:

- `&replicaSet=rs0` — without it, transactions still fail
- `authSource=admin` — root user lives in the admin DB
- Percent-encode special characters in the password (`@` → `%40`, `#` → `%23`,
  `/` → `%2F`, `:` → `%3A`)
- Quote the full URL so `&` is not broken by shell/env parsers

Then redeploy the app.

#### Step 7 — Verify app connectivity

```bash
docker ps | grep -i <app-name>
docker exec <app_container_id> getent hosts mongodb
# Expect: an IP returned = name resolves
```

Optional transaction smoke test:

```bash
docker exec mongodb mongosh -u "$MONGO_USER" -p "$MONGO_PASSWORD" \
  --authenticationDatabase admin --quiet --eval \
  'const s=db.getMongo().startSession(); s.startTransaction(); s.getDatabase("test").t.insertOne({x:1}); s.commitTransaction(); print("transaction OK")'
# Expect: transaction OK
```

### Quick reference — later status checks

```bash
# Replica set state (1 = primary)
docker exec mongodb mongosh -u USER -p PASS --authenticationDatabase admin --quiet --eval 'rs.status().myState'

# Full status
docker exec mongodb mongosh -u USER -p PASS --authenticationDatabase admin --eval 'rs.status()'

# Oplog / replication info
docker exec mongodb mongosh -u USER -p PASS --authenticationDatabase admin --quiet --eval 'rs.printReplicationInfo()'

# Networks
docker inspect mongodb --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
```

### Troubleshooting


| Symptom | Fix |
| ------- | --- |
| `Command replSetInitiate requires authentication` | `${MONGO_USER}` / `${MONGO_PASSWORD}` were empty — run Step 2 exports |
| `No primary exists` / `oplog.rs not found` in logs | Normal until `rs.initiate()` — do Step 3 |
| App: `Unable to connect to the database. Retrying...` (Mongoose) | Network gap — Step 5 (`dokploy-network`); URL must include `&replicaSet=rs0` (Step 6) |
| keyfile permission error on startup | `chmod 400` + `chown 999:999` keyfile, then `--force-recreate` |
| yaml: `mapping key 'test' already defined` | Duplicate healthcheck/block in compose — remove one; validate with `docker compose config` |
```

