# Adding n8n (workflow automation)

This guide brings n8n online on `n8n.infra.navexra.com`, reusing the existing
Postgres from `docker-compose.yml` and the host-level nginx for TLS. n8n runs
in its own compose project so its lifecycle (pulls, restarts, upgrades) is
isolated from the database stack.

```
                ┌────────────────────────────────────────────┐
   Internet ──▶ │ :443  host nginx (TLS for n8n.infra…)      │
                └──────────────────┬─────────────────────────┘
                                   │ 127.0.0.1:5678
                                   ▼
                              ┌──────────┐
                              │   n8n    │  (docker-compose.n8n.yml)
                              └────┬─────┘
                                   │ infra_db_net (external)
                                   ▼
                              ┌──────────┐
                              │ postgres │  (docker-compose.yml)
                              └──────────┘
```

Resource footprint: ~0.4 vCPU / 768 MB — fits inside the existing 2 vCPU / 8 GB budget.

---

## 1. Make `db_net` shareable across compose projects

The main `docker-compose.yml` pins a stable name on `db_net`:

```yaml
networks:
  db_net:
    name: infra_db_net
    driver: bridge
```

Recreate the network so the new name takes effect (causes a brief
reconnect of `postgres` and `redis`; run during a quiet window):

```bash
docker compose up -d
docker network ls | grep infra_db_net
```

---

## 2. Bootstrap a dedicated n8n DB + rolen

Keeps n8n's data isolated from `appdb`. Replace `<STRONG_PASSWORD>` with the
same value you put in `.env.n8n` as `N8N_DB_PASSWORD`.

```bash
docker compose exec postgres psql -U "$POSTGRES_USER" -d postgres <<'SQL'
CREATE USER n8n WITH PASSWORD '<STRONG_PASSWORD>';
CREATE DATABASE n8n OWNER n8n;
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
SQL
```

Verify:

```bash
docker compose exec postgres psql -U n8n -d n8n -c '\conninfo'
```

---

## 3. Configure `.env.n8n`

```bash
cp .env.n8n.example .env.n8n
# then edit and set:
#   N8N_DB_PASSWORD     (same value used in the SQL above)
#   N8N_ENCRYPTION_KEY  (one-time: openssl rand -hex 32)
```

`N8N_ENCRYPTION_KEY` is **critical** — if it ever changes, all stored
credentials become unreadable. Back it up alongside your other secrets.

---

## 4. Host nginx vhost

Create `/etc/nginx/sites-available/n8n.infra.navexra.com`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name n8n.infra.navexra.com;

    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name n8n.infra.navexra.com;

    ssl_certificate     /etc/letsencrypt/live/n8n.infra.navexra.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/n8n.infra.navexra.com/privkey.pem;

    # n8n executions / file uploads can be large; binary data and long-running
    # workflows need generous read/send timeouts.
    client_max_body_size 50m;
    proxy_read_timeout   3600s;
    proxy_send_timeout   3600s;

    location / {
        proxy_pass         http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_set_header   X-Forwarded-Host  $host;
        # WebSocket upgrade — required for the n8n editor UI
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }
}
```

Enable + reload:

```bash
sudo ln -s /etc/nginx/sites-available/n8n.infra.navexra.com \
           /etc/nginx/sites-enabled/n8n.infra.navexra.com
sudo nginx -t && sudo systemctl reload nginx
```

Pre-reqs:

- DNS `A` (and optionally `AAAA`) for `n8n.infra.navexra.com` → VPS IP.
- Issue the cert, e.g. `sudo certbot --nginx -d n8n.infra.navexra.com`.

---

## 5. Bring n8n up

```bash
docker compose -f docker-compose.n8n.yml --env-file .env.n8n config   # validate
docker compose -f docker-compose.n8n.yml --env-file .env.n8n pull
docker compose -f docker-compose.n8n.yml --env-file .env.n8n up -d

docker compose -f docker-compose.n8n.yml logs -f n8n
# wait for: "Editor is now accessible via: http://localhost:5678"

curl -sf http://127.0.0.1:5678/healthz    # {"status":"ok"}
```

Open `https://n8n.infra.navexra.com` and complete the owner-setup wizard
(this creates your first admin user — keep those credentials safe).

---

## 6. Day-2 operations

- **Upgrade**: prefer `./scripts/upgrade-n8n.sh <version>` (backs up DB and
keeps `n8nio/n8n` + `n8nio/runners` tags in sync). Manual: bump both image
tags in `docker-compose.n8n.yml`, then
`docker compose -f docker-compose.n8n.yml --env-file .env.n8n pull && docker compose -f docker-compose.n8n.yml --env-file .env.n8n up -d`.
- **Tail logs**: `docker compose -f docker-compose.n8n.yml logs -f n8n` (and
`… logs -f task-runners` if Code nodes fail).
- **Backup**: nightly `pg_dump n8n` on the `postgres` container covers
workflows and credentials. The `n8n_data` volume only holds runtime
scratch (binary-data references, encryption-key cache, etc.) but is
worth snapshotting too.
- **Scale**: if you start hitting concurrency limits, switch to queue mode
(main + worker + Redis-backed Bull queue). The existing `redis` service
is already on `infra_db_net` and reachable as `redis:6379`.

