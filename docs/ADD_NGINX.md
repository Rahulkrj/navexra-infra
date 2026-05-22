# Adding Nginx as a Reverse Proxy

This guide extends the existing `docker-compose.yml` (Postgres + Redis) with an
Nginx reverse proxy that terminates TLS and forwards public traffic to your
application containers. It fits inside the original 2 vCPU / 8 GB budget
(Nginx is allotted ~0.1 vCPU and ~128 MB RAM).

The stack ends up looking like this:

```
                ┌────────────────────────────────────────────┐
   Internet ──▶ │ :80  / :443   nginx (reverse proxy + TLS)  │
                └──────┬──────────────────────────┬──────────┘
                       │ web_net                  │ web_net
                       ▼                          ▼
                  ┌──────────┐              ┌──────────┐
                  │   app    │              │  api     │  ...your services
                  └────┬─────┘              └────┬─────┘
                       │ db_net                   │ db_net
                       ▼                          ▼
                 ┌──────────┐               ┌──────────┐
                 │ postgres │               │  redis   │
                 └──────────┘               └──────────┘
```

Two networks are used so that:

- The DBs are reachable only from app containers (`db_net`, internal).
- The proxy talks only to app containers, never directly to DBs (`web_net`).

---

## 1. Directory layout

Create these files alongside `docker-compose.yml`:

```
.
├── docker-compose.yml
├── .env
├── nginx/
│   ├── nginx.conf            # global config
│   ├── conf.d/
│   │   └── default.conf      # per-site server blocks
│   └── snippets/
│       ├── tls.conf          # shared TLS settings
│       └── security.conf     # shared security headers
└── certbot/
    ├── conf/                 # Let's Encrypt certs (persistent)
    └── www/                  # ACME http-01 challenge webroot
```

```bash
mkdir -p nginx/conf.d nginx/snippets certbot/conf certbot/www
```

---

## 2. Nginx config files

### `nginx/nginx.conf`

```nginx
user  nginx;
worker_processes  auto;
worker_rlimit_nofile 8192;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events {
    worker_connections  2048;
    multi_accept        on;
    use                 epoll;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Logging
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for" '
                      'rt=$request_time uct=$upstream_connect_time '
                      'urt=$upstream_response_time';
    access_log  /var/log/nginx/access.log  main;

    # Performance
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    keepalive_requests 1000;
    server_tokens   off;

    # Compression
    gzip              on;
    gzip_vary         on;
    gzip_proxied      any;
    gzip_comp_level   6;
    gzip_min_length   1024;
    gzip_types        text/plain text/css text/xml application/json
                      application/javascript application/xml+rss
                      application/atom+xml image/svg+xml;

    # Buffers / limits
    client_max_body_size       25m;
    client_body_buffer_size    128k;
    client_header_buffer_size  1k;
    large_client_header_buffers 4 8k;

    # Proxy defaults
    proxy_http_version 1.1;
    proxy_set_header   Host              $host;
    proxy_set_header   X-Real-IP         $remote_addr;
    proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto $scheme;
    proxy_set_header   X-Forwarded-Host  $host;
    proxy_set_header   Upgrade           $http_upgrade;
    proxy_set_header   Connection        $connection_upgrade;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;

    # Required for WebSocket upgrades on a per-connection basis
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    # Basic rate limiting zone (10 r/s with bursts; tweak per route)
    limit_req_zone $binary_remote_addr zone=req_per_ip:10m rate=10r/s;

    include /etc/nginx/conf.d/*.conf;
}
```

### `nginx/snippets/tls.conf`

```nginx
ssl_protocols             TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers               ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_session_cache         shared:SSL:10m;
ssl_session_timeout       1d;
ssl_session_tickets       off;
ssl_stapling              on;
ssl_stapling_verify       on;
resolver                  1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout          5s;
```

### `nginx/snippets/security.conf`

```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options    "nosniff" always;
add_header X-Frame-Options           "SAMEORIGIN" always;
add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
add_header Permissions-Policy        "geolocation=(), microphone=(), camera=()" always;
```

### `nginx/conf.d/default.conf`

Replace `example.com` with your domain and `app:3000` with your upstream
container's `service:port`.

```nginx
# ── HTTP: ACME challenges + redirect everything else to HTTPS ──
server {
    listen       80;
    listen       [::]:80;
    server_name  example.com www.example.com;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# ── HTTPS ──
server {
    listen       443 ssl;
    listen       [::]:443 ssl;
    http2        on;
    server_name  example.com www.example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
    include /etc/nginx/snippets/tls.conf;
    include /etc/nginx/snippets/security.conf;

    # Optional rate limit for login / auth endpoints
    location /auth/ {
        limit_req zone=req_per_ip burst=20 nodelay;
        proxy_pass http://app:3000;
    }

    location / {
        proxy_pass http://app:3000;
    }
}
```

---

## 3. Compose changes

Append the following to `docker-compose.yml`. (The DBs stay on `db_net`; Nginx
and your apps share `web_net`; apps are members of **both** networks so they
can reach the DBs but the proxy cannot.)

### Add a `web_net` network

Under the existing `networks:` block:

```yaml
networks:
  db_net:
    driver: bridge
  web_net:
    driver: bridge
```

### Add the `nginx` service

```yaml
  # ───────────────────────────────────────────
  #  Nginx  — TLS termination + reverse proxy
  # ───────────────────────────────────────────
  nginx:
    image: nginx:1.27-alpine
    container_name: nginx
    restart: unless-stopped
    networks:
      - web_net
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/snippets:/etc/nginx/snippets:ro
      - ./certbot/conf:/etc/letsencrypt:ro
      - ./certbot/www:/var/www/certbot:ro
    depends_on:
      - app   # replace with your real upstream service(s)
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    deploy:
      resources:
        limits:
          cpus: "0.1"
          memory: 128M
        reservations:
          cpus: "0.02"
          memory: 32M
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1/healthz || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
```

> **`/healthz`**: add a simple `location = /healthz { return 200 'ok'; add_header Content-Type text/plain; }` block in `default.conf` (outside the TLS server) if you want the healthcheck above to succeed.

### Example app service (template)

Drop this in once you have a real app image. Notice it's on **both** networks.

```yaml
  app:
    image: your-org/your-app:latest
    container_name: app
    restart: unless-stopped
    networks:
      - web_net   # so nginx can reach it
      - db_net    # so it can reach postgres / redis
    environment:
      DATABASE_URL: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}
      REDIS_URL:    redis://:${REDIS_PASSWORD}@redis:6379/0
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    deploy:
      resources:
        limits:
          cpus: "0.8"
          memory: 1024M
```

### Remove the host port bindings on the DBs (optional, recommended)

Once apps reach Postgres/Redis through `db_net`, you can delete the
`ports:` blocks from `postgres` and `redis` so they're not bound to the host
at all. Keep them only if you genuinely need `psql` / `redis-cli` from the
host shell.

---

## 4. TLS certificates with Let's Encrypt

Use the official `certbot/certbot` image. The flow is: bring nginx up on
port 80 with the ACME webroot, run certbot once to issue the cert, reload
nginx, then schedule renewals.

### One-time issuance

```bash
docker compose up -d nginx

docker run --rm -it \
  -v "$(pwd)/certbot/conf:/etc/letsencrypt" \
  -v "$(pwd)/certbot/www:/var/www/certbot" \
  certbot/certbot certonly \
    --webroot --webroot-path=/var/www/certbot \
    --email you@example.com --agree-tos --no-eff-email \
    -d example.com -d www.example.com

docker compose exec nginx nginx -s reload
```

### Renewal (cron / systemd timer on the host)

```cron
0 3 * * * docker run --rm \
  -v /path/to/certbot/conf:/etc/letsencrypt \
  -v /path/to/certbot/www:/var/www/certbot \
  certbot/certbot renew --quiet \
  && docker compose -f /path/to/docker-compose.yml exec -T nginx nginx -s reload
```

### Or: bake certbot into Compose

If you'd rather keep everything in `docker-compose.yml`:

```yaml
  certbot:
    image: certbot/certbot:latest
    container_name: certbot
    restart: unless-stopped
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    entrypoint: >
      sh -c 'trap exit TERM;
             while :; do
               certbot renew --webroot --webroot-path=/var/www/certbot --quiet;
               sleep 12h & wait $${!};
             done'
```

…and reload nginx hourly via a separate shell or by mounting
`/var/run/docker.sock` (the cron-on-host approach is simpler and safer).

---

## 5. Bring it up

```bash
docker compose config              # validate
docker compose up -d
docker compose ps
docker compose logs -f nginx
```

Smoke tests:

```bash
curl -I http://example.com/                    # expect 301 → https
curl -I https://example.com/                   # expect 200 + HSTS header
curl -I https://example.com/healthz            # expect 200 ok
```

Verify TLS grade: <https://www.ssllabs.com/ssltest/analyze.html?d=example.com>

---

## 6. Operational notes

- **Reload config without downtime:** `docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload`
- **Tail real-time errors:** `docker compose logs -f nginx | grep -E 'error|crit|alert|emerg'`
- **Behind a load balancer / Cloudflare?** Append `set_real_ip_from <upstream-cidr>;` and `real_ip_header X-Forwarded-For;` to `nginx.conf` so logs and `$remote_addr` show real client IPs.
- **HTTP/3 / QUIC:** add `listen 443 quic reuseport;` and `add_header Alt-Svc 'h3=":443"; ma=86400';` once you've upgraded to nginx 1.25+ with QUIC compiled in (the official `nginx:1.27-alpine` image already includes it).
- **Rate-limit tuning:** the `req_per_ip` zone is global; copy it for hot endpoints with different limits (e.g. `auth` at 5 r/s, `api` at 50 r/s).
