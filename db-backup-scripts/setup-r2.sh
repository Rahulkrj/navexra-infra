#!/usr/bin/env bash
# =============================================================================
#  SETUP (ek baar chalao)  —  rclone install + R2 configure + test
#  Neeche CONFIG bharein, phir: bash setup-r2.sh
# =============================================================================
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIG — apni R2 details bharein (Cloudflare R2 API token se milti hain)
# ─────────────────────────────────────────────────────────────────────────────
R2_ACCESS_KEY="PASTE_ACCESS_KEY_HERE"
R2_SECRET_KEY="PASTE_SECRET_KEY_HERE"
R2_ACCOUNT_ID="PASTE_ACCOUNT_ID_HERE"          # endpoint ka hissa
R2_BUCKET="PASTE_BUCKET_NAME_HERE"             # jaise: navexra-backups
# =============================================================================

die(){ echo "❌ $*" >&2; exit 1; }

[ "$R2_ACCESS_KEY" = "PASTE_ACCESS_KEY_HERE" ] && die "CONFIG bharein pehle (R2 credentials)."

echo "[1/4] rclone install kar rahe hain..."
if ! command -v rclone >/dev/null; then
  curl -fsSL https://rclone.org/install.sh | sudo bash
else
  echo "     rclone pehle se maujood: $(rclone version | head -1)"
fi

echo "[2/4] R2 remote configure kar rahe hain (non-interactive)..."
mkdir -p ~/.config/rclone
# Agar 'r2' remote pehle se hai to purana hata ke naya likhte hain
rclone config delete r2 2>/dev/null || true
cat >> ~/.config/rclone/rclone.conf <<EOF

[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
region = auto
acl = private
EOF

echo "[3/4] Connection test — bucket list:"
rclone lsd r2: || die "R2 connect nahi hua. Credentials/endpoint check karein."

echo "[4/4] Write test — bucket mein ek file bhej ke hata rahe hain:"
echo "backup-test-$(date +%s)" | rclone rcat "r2:${R2_BUCKET}/_setuptest.txt" \
  || die "Bucket '${R2_BUCKET}' mein likh nahi paaye. Bucket naam / permission check karein."
rclone delete "r2:${R2_BUCKET}/_setuptest.txt"

echo ""
echo "✅ R2 setup complete. Remote 'r2:' ready hai, bucket '${R2_BUCKET}' likhne layak hai."
echo "   Ab backup-to-r2.sh script chala sakte hain."