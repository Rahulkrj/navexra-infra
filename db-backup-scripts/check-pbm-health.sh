#!/usr/bin/env bash
# =============================================================================
#  CHECK — PBM (MongoDB backup) health: PITR staleness + last base backup.
#  Cron ke liye, har ~15 min. Fail/stale ho to n8n webhook par alert bhejta hai.
#
#  'pbm list -o json' schema verified locally (2026-10-02) against
#  percona/percona-backup-mongodb:2 (v2.16.0) using a throwaway Docker test
#  stack (mongo replica set + S3Mock + pbm-agent) — NOT against the real VPS.
#  Re-verify (docker exec pbm-agent pbm list -o json | jq .) if/when the PBM
#  image version on the VPS differs meaningfully from 2.16.0.
#
#  Test:  bash check-pbm-health.sh
# =============================================================================
set -uo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:$PATH"

# -----------------------------------------------------------------------------
#  CONFIG
# -----------------------------------------------------------------------------
PBM_CONTAINER="pbm-agent"
STALE_THRESHOLD_MIN=15      # isse zyada purana PITR chunk = stale alert

ALERT_WEBHOOK_URL="PASTE_N8N_WEBHOOK_URL_HERE"   # e.g. https://n8n.infra.navexra.com/webhook/backup-health-alert
ALERT_SECRET_HEADER="x-backup-secret"
ALERT_SECRET_VALUE="PASTE_SHARED_SECRET_HERE"     # n8n webhook ke onlyRunIf check wali hi value

LOG_FILE="/var/log/pbm-health.log"
# =============================================================================

log(){ echo "[$(date +%F' '%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

alert(){
  local status="$1" message="$2"
  log "ALERT (${status}): ${message}"
  curl -fsS -X POST "$ALERT_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -H "${ALERT_SECRET_HEADER}: ${ALERT_SECRET_VALUE}" \
    -d "$(jq -n --arg status "$status" --arg message "$message" --arg lastChunkAt "${LAST_CHUNK_EPOCH:-unknown}" \
          '{service:"mongodb-pbm", status:$status, message:$message, lastChunkAt:$lastChunkAt}')" \
    >>"$LOG_FILE" 2>&1 || log "WARN: alert webhook call khud fail ho gaya (network/n8n down?)"
}

LIST_JSON=$(docker exec "$PBM_CONTAINER" pbm list -o json 2>/tmp/pbm_list_err.log)
if [ $? -ne 0 ] || [ -z "$LIST_JSON" ]; then
  alert "failed" "pbm list command hi fail ho gaya (agent down/storage unreachable?): $(tail -1 /tmp/pbm_list_err.log 2>/dev/null)"
  exit 1
fi

# --- Last base backup status (soft check — alert karo par block mat karo) ---
LAST_SNAPSHOT_STATUS=$(echo "$LIST_JSON" | jq -r '.snapshots[-1].status // empty' 2>/dev/null)
if [ -n "$LAST_SNAPSHOT_STATUS" ] && [ "$LAST_SNAPSHOT_STATUS" != "done" ]; then
  alert "base-backup-not-done" "Last base backup status: '${LAST_SNAPSHOT_STATUS}' (expected 'done')."
fi

# --- PITR chalu hai? ---
PITR_ON=$(echo "$LIST_JSON" | jq -r '.pitr.on // false' 2>/dev/null)
if [ "$PITR_ON" != "true" ]; then
  alert "pitr-off" "pbm list mein 'pitr.on' true nahi hai — PITR chalu nahi hai ya error mein hai (pbm status se error dekho)."
  exit 1
fi

# --- Last PITR chunk kitna purana hai? (range.end already epoch seconds hai) ---
LAST_CHUNK_EPOCH=$(echo "$LIST_JSON" | jq -r '.pitr.ranges[-1].range.end // empty' 2>/dev/null)
if [ -z "$LAST_CHUNK_EPOCH" ] || ! [[ "$LAST_CHUNK_EPOCH" =~ ^[0-9]+$ ]]; then
  alert "no-chunks" "Koi PITR chunk range nahi mila 'pbm list -o json' mein — jq path verify karein (PBM version mismatch ho sakta hai)."
  exit 1
fi

AGE_MIN=$(( ($(date +%s) - LAST_CHUNK_EPOCH) / 60 ))
if [ "$AGE_MIN" -gt "$STALE_THRESHOLD_MIN" ]; then
  alert "stale" "Last PITR chunk ${AGE_MIN} min purana hai (threshold: ${STALE_THRESHOLD_MIN} min)."
  exit 1
fi

log "OK — PITR fresh (${AGE_MIN} min old, threshold ${STALE_THRESHOLD_MIN} min)."
exit 0
