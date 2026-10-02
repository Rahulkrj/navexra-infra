#!/usr/bin/env bash
# =============================================================================
#  SETUP (ek baar chalao, pbm-agent container up hone ke baad)
#  Percona Backup for MongoDB (PBM) — dedicated Mongo user + storage (R2) +
#  PITR + scheduled base backups.
#  Neeche CONFIG bharein, phir: bash setup-pbm.sh
# =============================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIG
# ─────────────────────────────────────────────────────────────────────────────

# --- R2 (same account/bucket jo setup-r2.sh mein use kiya tha) ---
R2_ACCESS_KEY="PASTE_ACCESS_KEY_HERE"      # verify: iska scope PBM_PREFIX par likhne ki ijaazat de
R2_SECRET_KEY="PASTE_SECRET_KEY_HERE"
R2_ACCOUNT_ID="PASTE_ACCOUNT_ID_HERE"
R2_BUCKET="PASTE_BUCKET_NAME_HERE"          # wahi bucket jo setup-r2.sh mein tha
PBM_PREFIX="pbm"                             # naya folder — legacy "backups/" se alag

# --- Container names ---
MONGO_CONTAINER="mongodb"
PBM_CONTAINER="pbm-agent"

# --- Mongo root creds (sirf ek baar, naya PBM user banane ke liye use honge) ---
MONGO_ROOT_USER="PASTE_MONGO_ROOT_USER_HERE"
MONGO_ROOT_PASS="PASTE_MONGO_ROOT_PASS_HERE"

# --- Naya dedicated PBM user — .env ke PBM_MONGO_USER/PBM_MONGO_PASSWORD se match hona chahiye ---
PBM_MONGO_USER="PASTE_PBM_MONGO_USER_HERE"
PBM_MONGO_PASS="PASTE_PBM_MONGO_PASS_HERE"

# --- PITR + backup schedule ---
PITR_OPLOG_SPAN_MIN="1"        # chunk-flush interval; isse tight RPO milta hai (minutes mein)
BASE_BACKUP_CRON="0 2 * * *"   # daily 02:00 UTC — off-peak hour, zaroorat ho to badlein
RETENTION_KEEP="7"             # last 7 base backups (+ unki oplog chains) rakho
# =============================================================================

die(){ echo "❌ $*" >&2; exit 1; }

[ "$R2_ACCESS_KEY" = "PASTE_ACCESS_KEY_HERE" ] && die "CONFIG bharein pehle."

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
    endpointUrl: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
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
