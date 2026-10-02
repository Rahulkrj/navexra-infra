#!/usr/bin/env bash
# =============================================================================
#  BACKUP  —  PostgreSQL (saara server)  ->  local  ->  R2
#  MongoDB ab isse backup nahi hota — Percona Backup for MongoDB (PBM) use
#  hota hai, see db-backup-scripts/README.md "MongoDB backups (PBM)" section.
#  Cron ke liye. Ek baar setup-r2.sh chal chuka hona chahiye.
#  Test:  bash backup-to-r2.sh
# =============================================================================
set -uo pipefail   # -e nahi: DB fail ho to bhi R2 upload/cleanup chalta rahe

# cron ka PATH chhota hota hai — docker/rclone dhundhne ke liye:
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:$PATH"

# -----------------------------------------------------------------------------
#  CONFIG
# -----------------------------------------------------------------------------

# --- Kya-kya backup karna hai? (true/false) ---
BACKUP_POSTGRES="true"

# --- Container names (docker ps se) ---
PG_CONTAINER="postgres"

# --- R2 ---
R2_BUCKET="PASTE_BUCKET_NAME_HERE"     # wahi jo setup-r2.sh mein tha
R2_PREFIX="backups"                     # bucket ke andar folder

# --- Local storage + retention ---
LOCAL_DIR="/root/backups"
KEEP_LOCAL_DAYS=3      # local mein itne din rakho
KEEP_R2_DAYS=30        # R2 par itne din rakho (offsite)

# Credentials khaali chhodenge to container se auto-detect (recommended)
PG_USER=""
PG_PASS=""

# =============================================================================
#  CONFIG khatam
# =============================================================================

STAMP=$(date +%F_%H%M)
mkdir -p "$LOCAL_DIR"
FAILED=0

log(){ echo "[$(date +%H:%M:%S)] $*"; }
warn(){ echo "WARN: $*" >&2; FAILED=1; }

# -- Postgres backup (pg_dumpall = saara server) --
if [ "$BACKUP_POSTGRES" = "true" ]; then
  log "Postgres backup shuru..."
  PU=${PG_USER:-$(docker exec "$PG_CONTAINER" printenv POSTGRES_USER 2>/dev/null)}
  PP=${PG_PASS:-$(docker exec "$PG_CONTAINER" printenv POSTGRES_PASSWORD 2>/dev/null)}
  PFILE="$LOCAL_DIR/pg_all_${STAMP}.sql.gz"

  if docker exec -e PGPASSWORD="$PP" "$PG_CONTAINER" \
        pg_dumpall -U "$PU" 2>/tmp/pg_err.log | gzip > "$PFILE"; then
    if [ -s "$PFILE" ] && gzip -t "$PFILE" 2>/dev/null; then
      log "  Postgres dump OK: $(du -h "$PFILE" | cut -f1)"
    else
      warn "Postgres dump khaali/corrupt: $(tail -1 /tmp/pg_err.log 2>/dev/null)"; rm -f "$PFILE"
    fi
  else
    warn "Postgres dump fail: $(tail -1 /tmp/pg_err.log 2>/dev/null)"; rm -f "$PFILE"
  fi
fi

# -- R2 upload (offsite) --
log "R2 par upload kar rahe hain..."
if rclone copy "$LOCAL_DIR/" "r2:${R2_BUCKET}/${R2_PREFIX}/" \
     --include "*_${STAMP}.*" --transfers 2 2>/tmp/r2_err.log; then
  log "  R2 upload OK."
else
  warn "R2 upload FAIL - offsite copy nahi bani! $(tail -1 /tmp/r2_err.log 2>/dev/null)"
fi

# -- Cleanup: local --
find "$LOCAL_DIR" -type f \( -name '*.archive' -o -name '*.sql.gz' \) \
  -mtime +$KEEP_LOCAL_DAYS -delete 2>/dev/null || true

# -- Cleanup: R2 --
rclone delete "r2:${R2_BUCKET}/${R2_PREFIX}/" \
  --min-age "${KEEP_R2_DAYS}d" 2>/dev/null || true

# -- Result --
echo ""
if [ "$FAILED" = "0" ]; then
  log "OK Backup complete - local + R2 dono OK."
  exit 0
else
  log "FAIL Backup mein kuch fail hua (upar WARN dekhein)."
  exit 1
fi