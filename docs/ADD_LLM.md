# Adding a Personal LLM Gateway (OpenAI-compatible)

This guide brings a personal LLM gateway online on `llm.infra.navexra.com`,
reusing the existing Postgres from `docker-compose.yml` and the host-level nginx
for TLS. It runs in its own compose project (`docker-compose.llm.yml`) so its
lifecycle is isolated from the database stack.

A single OpenAI-compatible endpoint (LiteLLM) routes by model name to:

- **Claude** — your Claude Pro/Max subscription, via `claude-code-openai-wrapper`.
- **ChatGPT** — your ChatGPT Plus/Pro subscription, via `codex-adapter` (see docs/ADD_CHATGPT.md).
- **Cursor** — your Cursor Pro subscription, via a small `cursor-adapter` (optional).
- **Local/offline** — Ollama (optional; tiny CPU models only on this box).

```
                ┌────────────────────────────────────────────┐
   Internet ──▶ │ :443  host nginx (TLS for llm.infra…)      │
                └──────────────────┬─────────────────────────┘
                                   │ 127.0.0.1:4000
                                   ▼
                         ┌───────────────────┐
                         │   litellm (4000)  │  OpenAI-compatible router
                         └───┬───────┬───────┘
              claude-*       │       │   cursor-*  (profile: cursor)
                             ▼       ▼
                ┌────────────────┐  ┌────────────────┐
                │ claude-wrapper │  │ cursor-adapter │
                │     (8000)     │  │     (8010)     │
                └───────┬────────┘  └───────┬────────┘
        CLAUDE_CODE_OAUTH_TOKEN        CURSOR_API_KEY
                             │  (LiteLLM keys + spend logs)
                             ▼
                       ┌──────────┐
                       │ postgres │  (docker-compose.yml)
                       └──────────┘
```

Resource footprint (core): ~0.6 vCPU / ~1 GB on top of Postgres + Redis + n8n.
This brings the box close to its 2 vCPU / 8 GB budget — watch headroom before
enabling the optional Ollama profile (which needs much more).

> **Terms of service.** Driving a Claude Pro/Max subscription from a server is a
> gray area in Anthropic's *consumer* terms — keep this strictly single-user and
> low-volume. The wrapper uses the officially supported `claude --print`
> subprocess pattern (it does not scrape tokens). The Cursor path uses an
> official **User API key**, which is the supported headless method.

---

## 1. Prerequisites

- The shared `infra_db_net` network exists (created by the main stack):
  ```bash
  docker compose up -d
  docker network ls | grep infra_db_net
  ```
- DNS `A` (and optionally `AAAA`) for `llm.infra.navexra.com` → VPS IP.

---

## 2. Mint the Claude subscription token (one-time, on your laptop)

Claude Code defaults to a browser OAuth flow, which a headless VPS can't
complete. Generate a long-lived token **on a machine with a browser**, then copy
it to the VPS.

```bash
# On your laptop:
npm i -g @anthropic-ai/claude-code
claude setup-token
# Log in with your Claude Pro/Max account in the browser when prompted.
# Copy the printed token (CLAUDE_CODE_OAUTH_TOKEN), valid ~1 year.
```

Put that value into `.env.llm` as `CLAUDE_CODE_OAUTH_TOKEN` (next step). Treat it
like a password and set a calendar reminder to rotate it before it expires.

---

## 3. Configure `.env.llm`

```bash
cp .env.llm.example .env.llm
# then edit and set, at minimum:
#   LITELLM_MASTER_KEY      (openssl rand -hex 32, keep the sk- style prefix)
#   LITELLM_SALT_KEY        (openssl rand -hex 32, must stay stable)
#   LLM_DB_PASSWORD         (used in the SQL below)
#   CLAUDE_CODE_OAUTH_TOKEN (from step 2)
#   CLAUDE_WRAPPER_API_KEY  (openssl rand -hex 24 — internal bearer)
```

`LITELLM_MASTER_KEY` and `LITELLM_SALT_KEY` are critical: the salt key encrypts
stored credentials in the DB, so changing it makes them unreadable. Back both up
with your other secrets.

---

## 4. Bootstrap a dedicated `litellm` DB + role

Keeps gateway data isolated from `appdb` / `n8n`. Use the same value you put in
`.env.llm` as `LLM_DB_PASSWORD`.

```bash
docker compose exec postgres psql -U "$POSTGRES_USER" -d postgres <<'SQL'
CREATE USER litellm WITH PASSWORD '<STRONG_PASSWORD>';
CREATE DATABASE litellm OWNER litellm;
GRANT ALL PRIVILEGES ON DATABASE litellm TO litellm;
SQL
```

Verify:

```bash
docker compose exec postgres psql -U litellm -d litellm -c '\conninfo'
```

LiteLLM creates its own tables (Prisma migrations) on first start.

---

## 5. Bring the core stack up (LiteLLM + Claude)

```bash
docker compose -f docker-compose.llm.yml --env-file .env.llm config   # validate
docker compose -f docker-compose.llm.yml --env-file .env.llm build     # builds claude-wrapper from upstream
docker compose -f docker-compose.llm.yml --env-file .env.llm up -d

docker compose -f docker-compose.llm.yml logs -f litellm claude-wrapper
```

Confirm the Claude wrapper authenticated with your subscription and see which
model IDs it advertises (adjust `llm/litellm-config.yaml` if they differ):

```bash
curl -s -H "Authorization: Bearer $CLAUDE_WRAPPER_API_KEY" \
     http://127.0.0.1:8000/v1/models | jq .
```

---

## 6. Host nginx vhost

Create `/etc/nginx/sites-available/llm.infra.navexra.com`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name llm.infra.navexra.com;

    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name llm.infra.navexra.com;

    ssl_certificate     /etc/letsencrypt/live/llm.infra.navexra.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/llm.infra.navexra.com/privkey.pem;

    # LLM responses can take a while (long completions / agentic runs) and
    # stream token-by-token; give generous timeouts and disable buffering.
    client_max_body_size 25m;
    proxy_read_timeout   3600s;
    proxy_send_timeout   3600s;

    location / {
        proxy_pass         http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_set_header   X-Forwarded-Host  $host;
        # Required for SSE streaming of chat completions.
        proxy_buffering    off;
        proxy_cache        off;
    }
}
```

Enable + issue the cert + reload:

```bash
sudo ln -s /etc/nginx/sites-available/llm.infra.navexra.com \
           /etc/nginx/sites-enabled/llm.infra.navexra.com
sudo certbot --nginx -d llm.infra.navexra.com
sudo nginx -t && sudo systemctl reload nginx
```

---

## 7. Mint a client (virtual) key and smoke test

The `LITELLM_MASTER_KEY` is for admin only. Mint a per-client virtual key for
n8n / your apps:

```bash
curl -s http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models": ["claude-sonnet", "claude-opus", "claude-haiku"], "key_alias": "n8n"}' | jq .
# → copy the returned "key" (sk-...)
```

Smoke test through the public endpoint:

```bash
curl -s https://llm.infra.navexra.com/v1/chat/completions \
  -H "Authorization: Bearer <virtual-key>" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "claude-sonnet",
        "messages": [{"role": "user", "content": "Say hello in one short sentence."}]
      }' | jq .
```

You should get a normal OpenAI `chat.completion` response.

### Using it from clients

- **OpenAI SDKs / apps:** `base_url = https://llm.infra.navexra.com/v1`,
  `api_key = <virtual-key>`, `model = claude-sonnet`.
- **n8n:** add an *OpenAI* credential with the Base URL above and the virtual
  key; pick the model name in the node.

---

## 8. (Optional) Phase 2 — add the Cursor backend

```bash
# In .env.llm set CURSOR_API_KEY (Cursor Dashboard → API Keys) and
# CURSOR_ADAPTER_API_KEY (openssl rand -hex 24), then:
docker compose -f docker-compose.llm.yml --env-file .env.llm --profile cursor up -d --build
```

Uncomment the `cursor-composer` entry in `llm/litellm-config.yaml`, then reload:

```bash
docker compose -f docker-compose.llm.yml --env-file .env.llm restart litellm
```

`cursor-agent` is an **agentic coding tool** with file-write access. The adapter
runs it in a throwaway temp directory and is non-streaming; treat `cursor-composer`
as a coding-task model, not a general chat model.

---

## 9. (Optional) Phase 3 — add a local/offline model

> **Heads up:** a 2 vCPU / 8 GB box can only run *tiny* CPU models (e.g.
> `qwen2.5:3b`), and slowly. For anything serious, run Ollama on a larger/GPU
> host and point a LiteLLM entry at it via `api_base` instead.

```bash
docker compose -f docker-compose.llm.yml --env-file .env.llm --profile local up -d
docker compose -f docker-compose.llm.yml exec ollama ollama pull qwen2.5:3b
```

Uncomment the `local-qwen` entry in `llm/litellm-config.yaml`, then
`docker compose -f docker-compose.llm.yml --env-file .env.llm restart litellm`.

Adding any other provider later (OpenAI, Groq, a remote Ollama, etc.) is just
another entry in `llm/litellm-config.yaml` — clients keep the same base URL and
key, and only change the `model` string.

---

## 10. Day-2 operations

- **Reload model config:** edit `llm/litellm-config.yaml`, then
  `docker compose -f docker-compose.llm.yml --env-file .env.llm restart litellm`.
- **Upgrade LiteLLM:** bump the `image:` tag, then `pull` + `up -d`.
- **Rebuild Claude wrapper / Cursor adapter:** `... up -d --build`.
- **Rotate the Claude token** before its ~1-year expiry (repeat step 2, update
  `.env.llm`, `restart claude-wrapper`).
- **Backup:** nightly `pg_dump litellm` covers virtual keys and spend logs. The
  `claude_config` volume holds the subscription session.
- **Tail logs:** `docker compose -f docker-compose.llm.yml logs -f litellm`.
