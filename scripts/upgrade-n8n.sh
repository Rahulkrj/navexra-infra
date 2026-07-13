#!/usr/bin/env bash
# Upgrade the pinned n8n Docker image safely.
#
# Run from the repo root on the machine running docker:
#   ./scripts/upgrade-n8n.sh 1.123.65          # recommended first hop from 1.117
#   ./scripts/upgrade-n8n.sh 2.29.10 --confirm-major   # after Migration Report
#   ./scripts/upgrade-n8n.sh 2.29.10 --dry-run
#
# What it does:
#   1. Backs up the n8n Postgres DB (and notes the data volume)
#   2. Updates image: n8nio/n8n:<version> in docker-compose.n8n.yml
#   3. pull + up -d, then waits for /healthz
#
# Recommended path from 1.117.0:
#   1.117.0 → 1.123.65  (unlock Settings → Migration Report)
#   fix Critical issues in the Migration Report
#   1.123.65 → 2.29.10  (current stable; use --confirm-major)
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE_FILE="docker-compose.n8n.yml"
ENV_FILE=".env.n8n"
BACKUP_DIR="${BACKUP_DIR:-./backups/n8n}"
DRY_RUN=0
CONFIRM_MAJOR=0
TARGET=""

usage() {
  cat <<'EOF'
Usage: ./scripts/upgrade-n8n.sh <version> [--dry-run] [--confirm-major]

Examples:
  ./scripts/upgrade-n8n.sh 1.123.65
  ./scripts/upgrade-n8n.sh 2.29.10 --confirm-major
  ./scripts/upgrade-n8n.sh 2.29.10 --dry-run

Env:
  BACKUP_DIR   Where to write pg_dump (default: ./backups/n8n)
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --confirm-major) CONFIRM_MAJOR=1 ;;
    -*)
      echo "ERROR: unknown flag: $arg"
      usage
      exit 1
      ;;
    *)
      if [ -n "$TARGET" ]; then
        echo "ERROR: unexpected extra argument: $arg"
        usage
        exit 1
      fi
      TARGET="$arg"
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  usage
  exit 1
fi

if ! [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: version must look like 1.123.65 or 2.29.10 (got: $TARGET)"
  exit 1
fi

[ -f "$COMPOSE_FILE" ] || { echo "ERROR: $COMPOSE_FILE not found"; exit 1; }
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (copy from .env.n8n.example)"; exit 1; }

CURRENT="$(grep -E '^\s*image:\s*n8nio/n8n:' "$COMPOSE_FILE" | head -1 | sed -E 's/.*n8nio\/n8n:([^[:space:]]+).*/\1/')"
[ -n "$CURRENT" ] || { echo "ERROR: could not parse current image tag from $COMPOSE_FILE"; exit 1; }

if [ "$CURRENT" = "$TARGET" ]; then
  echo "Already pinned to n8nio/n8n:$TARGET — nothing to do."
  exit 0
fi

CURRENT_MAJOR="${CURRENT%%.*}"
TARGET_MAJOR="${TARGET%%.*}"

echo "==> Current pin : n8nio/n8n:$CURRENT"
echo "==> Target pin  : n8nio/n8n:$TARGET"
[ "$DRY_RUN" -eq 1 ] && echo "==> Mode         : dry-run (no changes)"

if [ "$CURRENT_MAJOR" != "$TARGET_MAJOR" ]; then
  cat <<EOF

!! MAJOR VERSION JUMP ($CURRENT → $TARGET)
   Before upgrading 1.x → 2.x:
     1. Prefer hopping to latest 1.x first (e.g. 1.123.65)
     2. Open Settings → Migration Report and fix Critical issues
     3. Backup DB (this script does that)
     4. Re-run with --confirm-major

   Breaking-change docs:
     https://docs.n8n.io/2-0-breaking-changes/
     https://docs.n8n.io/migration-tool-v2/

EOF
  if [ "$CONFIRM_MAJOR" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    echo "ERROR: refusing major upgrade without --confirm-major"
    exit 1
  fi
fi

# shellcheck disable=SC1090
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

: "${N8N_DB_NAME:?N8N_DB_NAME missing in $ENV_FILE}"
: "${N8N_DB_USER:?N8N_DB_USER missing in $ENV_FILE}"
: "${N8N_DB_PASSWORD:?N8N_DB_PASSWORD missing in $ENV_FILE}"

compose() {
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

stamp="$(date +%Y%m%d-%H%M%S)"
backup_sql="$BACKUP_DIR/n8n-${CURRENT}-to-${TARGET}-${stamp}.sql.gz"

echo "==> Checking postgres is reachable..."
if [ "$DRY_RUN" -eq 1 ]; then
  if docker compose exec -T postgres pg_isready -q 2>/dev/null; then
    echo "    postgres is up (backup would run)"
  else
    echo "    (dry-run) postgres not reachable here — backup step would run on the host"
  fi
elif ! docker compose exec -T postgres pg_isready -q 2>/dev/null; then
  echo "ERROR: postgres container is not ready (is the core stack up?)"
  exit 1
fi

echo "==> Backing up Postgres DB '$N8N_DB_NAME' → $backup_sql"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    (dry-run) would run pg_dump and write $backup_sql"
else
  mkdir -p "$BACKUP_DIR"
  docker compose exec -T \
    -e PGPASSWORD="$N8N_DB_PASSWORD" \
    postgres \
    pg_dump -h 127.0.0.1 -U "$N8N_DB_USER" -d "$N8N_DB_NAME" --no-owner --no-acl \
    | gzip -c > "$backup_sql"
  # refuse empty / tiny dumps
  size="$(wc -c < "$backup_sql" | tr -d ' ')"
  if [ "$size" -lt 100 ]; then
    echo "ERROR: backup looks empty ($size bytes) — aborting"
    rm -f "$backup_sql"
    exit 1
  fi
  echo "    wrote $backup_sql ($size bytes)"
fi

echo "==> Note: also snapshot volume 'n8n_data' if you store binary data there:"
echo "    docker run --rm -v n8n_data:/data -v \"$PWD/${BACKUP_DIR#./}\":/backup alpine \\"
echo "      tar czf /backup/n8n_data-${stamp}.tgz -C /data ."

echo "==> Updating $COMPOSE_FILE image tag..."
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    (dry-run) would set image: n8nio/n8n:$TARGET"
else
  # Portable in-place edit (macOS + Linux)
  tmp="$(mktemp)"
  sed -E "s|(image:[[:space:]]*n8nio/n8n:)[^[:space:]]+|\\1${TARGET}|" "$COMPOSE_FILE" > "$tmp"
  if ! grep -q "n8nio/n8n:${TARGET}" "$tmp"; then
    echo "ERROR: failed to rewrite image tag"
    rm -f "$tmp"
    exit 1
  fi
  mv "$tmp" "$COMPOSE_FILE"
  echo "    pinned to n8nio/n8n:$TARGET"
fi

echo "==> Validating compose..."
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    (dry-run) would run: compose config / pull / up -d"
  echo "==> Dry-run complete."
  exit 0
fi

compose config >/dev/null

echo "==> Pulling n8nio/n8n:$TARGET ..."
compose pull n8n

echo "==> Recreating n8n..."
compose up -d n8n

echo "==> Waiting for healthz..."
ok=0
for i in $(seq 1 60); do
  if curl -sf http://127.0.0.1:5678/healthz 2>/dev/null | grep -qi ok; then
    ok=1
    break
  fi
  sleep 2
done

if [ "$ok" -ne 1 ]; then
  echo "ERROR: n8n did not become healthy in time. Recent logs:"
  compose logs --tail=80 n8n || true
  echo
  echo "Rollback tip:"
  echo "  1. Restore image tag to $CURRENT in $COMPOSE_FILE"
  echo "  2. compose pull && compose up -d"
  echo "  3. If DB migrated badly: gunzip -c $backup_sql | docker compose exec -T -e PGPASSWORD=... postgres psql -U $N8N_DB_USER -d $N8N_DB_NAME"
  exit 1
fi

echo
echo "==> Upgrade complete: $CURRENT → $TARGET"
echo "    Backup: $backup_sql"
echo "    Health: $(curl -sf http://127.0.0.1:5678/healthz)"
echo
if [ "$TARGET_MAJOR" = "1" ]; then
  # TARGET >= 1.121.0 → Migration Report is available
  if [ "$(printf '%s\n' "1.121.0" "$TARGET" | sort -V | head -1)" = "1.121.0" ]; then
    echo "Next: open Settings → Migration Report, fix Critical issues,"
    echo "then run: ./scripts/upgrade-n8n.sh 2.29.10 --confirm-major"
  else
    echo "Next: hop to latest 1.x first (e.g. 1.123.65) to unlock Migration Report."
  fi
fi
if [ "$TARGET_MAJOR" = "2" ]; then
  echo "Verify workflows still run. Breaking changes: https://docs.n8n.io/2-0-breaking-changes/"
fi
