#!/usr/bin/env bash
# =============================================================================
#  SETUP (ek baar chalao, pbm-agent container up hone ke baad)
#  Percona Backup for MongoDB (PBM) — dedicated Mongo user + storage (R2) +
#  PITR + scheduled base backups.
#
#  No secrets pasted here. Everything is auto-detected from stuff that
#  already exists on this VPS:
#    - R2 access key/secret/endpoint  <- ~/.config/rclone/rclone.conf [r2]
#      (written by setup-r2.sh — nothing new to type in)
#    - R2 bucket name                 <- backup-to-r2.sh's R2_BUCKET= line
#    - Mongo root user/pass           <- `docker exec mongodb printenv ...`
#      (same auto-detect trick backup-to-r2.sh already uses)
#    - PBM_MONGO_USER/PASSWORD        <- .env (has to live there anyway —
#      docker-compose.yml requires it for the pbm-agent service, same as
#      the existing MONGO_USER/MONGO_PASSWORD)
#
#  Only CONFIG left below is non-secret behavior knobs (schedule, retention,
#  prefix) and the auto-detect source paths, in case your layout differs.
#
#  Run: bash setup-pbm.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIG — mostly just paths + non-secret knobs
# ─────────────────────────────────────────────────────────────────────────────
RCLONE_CONF="${HOME}/.config/rclone/rclone.conf"       # setup-r2.sh ne yahan likha tha
BACKUP_SCRIPT="${SCRIPT_DIR}/backup-to-r2.sh"           # R2_BUCKET yahan se padhenge
ENV_FILE="${SCRIPT_DIR}/../.env"                        # PBM_MONGO_USER/PASSWORD yahan se

MONGO_CONTAINER="mongodb"
PBM_CONTAINER="pbm-agent"

PBM_PREFIX="pbm"                             # naya folder — legacy "backups/" se alag
PITR_OPLOG_SPAN_MIN="1"                      # chunk-flush interval; isse tight RPO milta hai (minutes mein)
BASE_BACKUP_CRON="0 2 * * *"                 # daily 02:00 UTC — off-peak hour, zaroorat ho to badlein
RETENTION_KEEP="7"                           # last 7 base backups (+ unki oplog chains) rakho
# =============================================================================

die(){ echo "❌ $*" >&2; exit 1; }

# -- auto-detect: R2 creds from rclone.conf's [r2] section --
rclone_get(){
  local key="$1"
  awk -v k="$key" '
    /^\[r2\]/ { insec=1; next }
    /^\[/     { insec=0 }
    insec {
      line=$0
      split(line, parts, "=")
      gsub(/^[ \t]+|[ \t]+$/, "", parts[1])
      if (parts[1]==k) { sub(/^[^=]*=[ \t]*/, "", line); print line; exit }
    }
  ' "$RCLONE_CONF"
}

[ -f "$RCLONE_CONF" ] || die "rclone.conf nahi mila ($RCLONE_CONF) — pehle setup-r2.sh chalao."
R2_ACCESS_KEY=$(rclone_get access_key_id)
R2_SECRET_KEY=$(rclone_get secret_access_key)
R2_ENDPOINT=$(rclone_get endpoint)
[ -n "$R2_ACCESS_KEY" ] && [ -n "$R2_SECRET_KEY" ] && [ -n "$R2_ENDPOINT" ] \
  || die "rclone.conf ke [r2] section se access_key_id/secret_access_key/endpoint nahi padh paye."

# -- auto-detect: bucket name from backup-to-r2.sh --
[ -f "$BACKUP_SCRIPT" ] || die "backup-to-r2.sh nahi mila ($BACKUP_SCRIPT)."
R2_BUCKET=$(grep -E '^R2_BUCKET=' "$BACKUP_SCRIPT" | head -1 | sed -E 's/^R2_BUCKET="?([^"]*)"?.*/\1/')
[ -n "$R2_BUCKET" ] && [ "$R2_BUCKET" != "PASTE_BUCKET_NAME_HERE" ] \
  || die "R2_BUCKET backup-to-r2.sh mein set nahi mila — pehle ye file configure karo."

# -- auto-detect: Mongo root creds from the running container's own env --
MONGO_ROOT_USER=$(docker exec "$MONGO_CONTAINER" printenv MONGO_INITDB_ROOT_USERNAME 2>/dev/null)
MONGO_ROOT_PASS=$(docker exec "$MONGO_CONTAINER" printenv MONGO_INITDB_ROOT_PASSWORD 2>/dev/null)
[ -n "$MONGO_ROOT_USER" ] && [ -n "$MONGO_ROOT_PASS" ] \
  || die "Mongo root creds container se nahi mile — '$MONGO_CONTAINER' chal raha hai aur sahi env hai?"

# -- auto-detect: dedicated PBM user from .env (must match docker-compose.yml) --
[ -f "$ENV_FILE" ] || die ".env nahi mila ($ENV_FILE)."
env_get(){ grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d'=' -f2-; }
PBM_MONGO_USER=$(env_get PBM_MONGO_USER)
PBM_MONGO_PASS=$(env_get PBM_MONGO_PASSWORD)
[ -n "$PBM_MONGO_USER" ] && [ -n "$PBM_MONGO_PASS" ] \
  || die "PBM_MONGO_USER/PBM_MONGO_PASSWORD .env mein nahi mile — pehle wahan add karo (docker-compose.yml ko bhi chahiye)."

echo "[1/5] Dedicated PBM Mongo user bana rahe hain (agar already nahi hai)..."
# NOTE: ye role-set PBM docs (https://docs.percona.com/percona-backup-mongodb/)
# ke against verify karein — installed PBM image version ke hisaab se role
# requirements badal sakte hain, blindly trust na karein.
docker exec "$MONGO_CONTAINER" mongosh -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASS" \
  --authenticationDatabase admin --quiet --eval "
    db.getSiblingDB('admin').createUser({
      user: '${PBM_MONGO_USER}',
      pwd: '${PBM_MONGO_PASS}',
      roles: [
        { db: 'admin', role: 'backup' },
        { db: 'admin', role: 'restore' },
        { db: 'admin', role: 'clusterMonitor' },
        { db: 'admin', role: 'readWrite', collection: '' }
      ]
    })
  " || echo "   (user shayad already exists — error upar check karein, warna aage badhein)"

echo "[2/5] PBM storage config likh rahe hain (R2, prefix=${PBM_PREFIX})..."
cat > /tmp/pbm-config.yaml <<EOF
storage:
  type: s3
  s3:
    region: auto
    bucket: ${R2_BUCKET}
    prefix: ${PBM_PREFIX}
    endpointUrl: ${R2_ENDPOINT}
    credentials:
      access-key-id: ${R2_ACCESS_KEY}
      secret-access-key: ${R2_SECRET_KEY}
pitr:
  enabled: true
  oplogSpanMin: ${PITR_OPLOG_SPAN_MIN}
backup:
  cronjobs:
    - type: logical
      compression: gzip
      schedule: "${BASE_BACKUP_CRON}"
      keep: ${RETENTION_KEEP}
EOF
docker cp /tmp/pbm-config.yaml "${PBM_CONTAINER}:/tmp/pbm-config.yaml"
docker exec "$PBM_CONTAINER" pbm config --file=/tmp/pbm-config.yaml \
  || die "pbm config fail — 'pbm config --help' se syntax/version check karein (PBM CLI version-se-version badal sakta hai)."
rm -f /tmp/pbm-config.yaml

echo "[3/5] Oplog window check kar rahe hain..."
docker exec "$MONGO_CONTAINER" mongosh -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASS" \
  --authenticationDatabase admin --quiet --eval 'rs.printReplicationInfo()'
echo "   ^ 'oplog window' (hours/minutes) dekho."
echo "   Agar pbm-agent kabhi ${PITR_OPLOG_SPAN_MIN} min se kaafi zyada der down rahega"
echo "   to is window se bada hona chahiye, warna PITR chain tootegi aur fresh"
echo "   base backup chahiye hoga. Window chhota lage to resize karo:"
echo '     db.adminCommand({ replSetResizeOplog: 1, size: 2048 })   # MB mein'
echo "   (isi mongosh session se, replSetResizeOplog retroactive resize karta hai — compose"
echo "    ke --oplogSize flag ka asar sirf naye oplog par hota hai, already-running node par nahi)"

echo "[4/5] PITR + backup status confirm kar rahe hain:"
docker exec "$PBM_CONTAINER" pbm status || die "pbm status fail — config/connectivity check karein."

echo "[5/5] Done."
echo ""
echo "✅ PBM setup complete."
echo "   - PITR chalu hona chahiye (upar 'pbm status' mein 'PITR incremental backup: ON')"
echo "   - Pehla daily base backup '${BASE_BACKUP_CRON}' (UTC) par chalega"
echo "   - R2 mein bucket '${R2_BUCKET}' ke andar '${PBM_PREFIX}/' folder mein data aayega"
echo ""
echo "   AGLA STEP: test restore zaroor karo (README.md ka PBM restore-test section) —"
echo "   tabhi backup-to-r2.sh se Mongo hataana (us cutover ko abhi skip karo)."
