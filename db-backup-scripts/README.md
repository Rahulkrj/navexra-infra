# Database Backup Setup — Navexra Infra

PostgreSQL ka automated backup (`backup-to-r2.sh`, host cron), Cloudflare R2 (offsite) par.
MongoDB ab isi script se backup nahi hota — **Percona Backup for MongoDB (PBM)** use hota hai
(continuous PITR + daily base backup, same R2 bucket, alag prefix). Dono systems ek hi R2
account/bucket share karte hain, bas alag-alag prefix mein.

> **Status: cutover complete (2026-10-03).** `backup-to-r2.sh` no longer dumps Mongo — PBM is the
> sole system of record for Mongo backups, validated live on production first (test restore +
> staleness alert, see "MongoDB backups (PBM)" below). See "Cutover" section at the bottom for
> the record of what changed and when.

---

## Overview

| Cheez | Detail |
|-------|--------|
| PostgreSQL | `backup-to-r2.sh`, saara server (`pg_dumpall`), har 4 ghante, local `/root/backups` + R2 `backups/` prefix |
| MongoDB | **PBM** — continuous PITR (oplog, ~1 min chunks) + daily base backup, R2 `pbm/` prefix (see "MongoDB backups (PBM)" section below) |
| Local retention (Postgres) | 3 din |
| R2 retention (Postgres) | 7 din |
| R2 retention (Mongo/PBM) | 7 din (configured via `setup-pbm.sh`) |
| Server time | UTC |

**Design note:** Databases Dokploy ke bahar, apni `docker-compose.yml` se chalte hain.
Isliye backup bhi Dokploy ke bahar, in scripts se hota hai (Dokploy ka built-in
DB-backup in external databases ko nahi dekhta).

---

## Files

```
/root/scripts/db-backup/
├── setup-r2.sh          # ek baar: rclone install + R2 configure (Postgres ke liye)
├── backup-to-r2.sh      # rozana (cron): Postgres dump + upload + cleanup
├── setup-pbm.sh         # ek baar: PBM Mongo user + storage(R2) + PITR + backup schedule config
├── check-pbm-health.sh  # har 15 min (cron): PITR staleness check -> Telegram alert
└── README.md            # ye file
```

---

## First-time setup (naye server par ye kram)

### 1. R2 setup (ek baar)
`setup-r2.sh` ke top par CONFIG bharein:
- `R2_ACCESS_KEY`, `R2_SECRET_KEY` — Cloudflare R2 API token se
- `R2_ACCOUNT_ID` — endpoint ka hissa
- `R2_BUCKET` — bucket ka naam

Phir:
```bash
bash setup-r2.sh
```
EXPECT: "R2 setup complete". Ye rclone install karta hai aur R2 test karta hai.

### 2. Backup script config
`backup-to-r2.sh` ke top par:
- `R2_BUCKET` — wahi bucket naam
- baaki defaults theek hain (credentials container se auto-detect hote hain)

### 3. Test (haath se)
```bash
bash backup-to-r2.sh
```
EXPECT:
```
Postgres dump OK: <size>
R2 upload OK
OK Backup complete - local + R2 dono OK
```

### 4. Cron mein chalega ya nahi — confirm (bina wait kiye)
Cron ka environment chhota hota hai. Ye command cron jaisa khaali env banakar test karti hai:
```bash
env -i PATH=/usr/bin:/bin /root/scripts/db-backup/backup-to-r2.sh
```
Chal gaya = cron mein bhi chalega.

### 5. Cron lagao
```bash
chmod +x /root/scripts/db-backup/backup-to-r2.sh
crontab -e
```
Ye line add karo:
```
0 */4 * * * /root/scripts/db-backup/backup-to-r2.sh >> /var/log/backup.log 2>&1
```
Confirm:
```bash
crontab -l
```

---

## MongoDB backups (PBM)

MongoDB runs as a single-node replica set (`rs0`) in `docker-compose.yml`, which is what makes
PITR (point-in-time recovery) possible — the oplog only exists on a replica set. PBM (`pbm-agent`
service) tails that oplog continuously and ships chunks to R2, plus runs a daily full logical
backup. RPO is roughly the PITR chunk span (default 1 minute, see `setup-pbm.sh`), not 4 hours.

### First-time setup

1. Bring up the new service: `docker compose up -d pbm-agent` (needs `PBM_MONGO_USER` /
   `PBM_MONGO_PASSWORD` in `.env` first — see `.env.example`).
2. Run `bash setup-pbm.sh` — no secrets to fill in, it auto-detects everything (R2 creds from
   `rclone.conf`, bucket from `backup-to-r2.sh`, Mongo root creds from the container, PBM user
   from `.env`). This creates the dedicated least-privilege Mongo user, configures PBM's S3/R2
   storage + PITR, sets the retention policy, and **generates `pbm-daily-backup.sh`** next to it
   — add the crontab line it prints (PBM has no built-in scheduler; it explicitly recommends host
   cron + `pbm backup`, so that's what this generated script does).
3. Run `bash pbm-daily-backup.sh` once manually — PITR won't actually start producing chunks
   until a base backup exists.
4. Confirm: `docker exec pbm-agent pbm status` should show PITR `[ON]` with no error, and a
   snapshot listed under Backups with `status: done`.

### MongoDB restore (PBM / point-in-time)

> ⚠️ **Any `pbm restore` command disables the PITR oplog slicer as a side effect — even a failed
> restore — and PBM then REQUIRES a fresh full base backup before PITR will resume, no matter
> what you set `pitr.enabled` to.** Confirmed on this project's VPS (2026-10-03), two-stage: a
> restore attempt silently killed PITR; toggling `pitr.enabled=false`/`true` looked like it fixed
> it (`pbm status` showed `[ON]`, chunks even seemed to continue for a while), but after the
> `pbm-agent` container was later restarted, `pbm status` revealed the real state: `ERROR while
> running PITR backup: ... no backup found after the restored <snapshot>, a new backup is
> required to resume PITR`. **After every restore (test or real), run:**
> ```bash
> bash /root/infra/navexra-infra/db-backup-scripts/pbm-daily-backup.sh   # or: docker exec pbm-agent pbm backup --wait
> sleep 70
> docker exec pbm-agent pbm status   # must show "Status [ON]" with NO error line
> docker exec pbm-agent pbm list -o json   # confirm pitr.ranges has a NEW range starting after the backup
> ```
> Toggling `pitr.enabled` off/on is not sufficient by itself and can look deceptively fine for a
> while — the fresh backup is what actually clears the "backup required" condition. Don't trust a
> clean-looking `pbm status` right after a restore; wait for a real new chunk to confirm it's
> actually producing data again.
> Also: if you issue `pbm config --set` within a few seconds of starting a restore, it'll fail with
> `another operation in progress` — wait for `Currently running: (none)` in `pbm status` first.

```bash
# List available restore points first:
docker exec pbm-agent pbm status
docker exec pbm-agent pbm list

# Full restore to the latest snapshot (IN PLACE — overwrites the live database):
docker exec pbm-agent pbm restore <snapshot-name> --yes

# Point-in-time restore (also IN PLACE):
docker exec pbm-agent pbm restore --time="2026-10-02T03:15:00" --yes
```
**PBM restores in place by default** — there is no wildcard/whole-database "restore into a
different name" option (confirmed against the real CLI: `--ns-from`/`--ns-to` only clone a single
named collection, not `db.*`). For a non-destructive test without touching the live database, use
`--ns-from`/`--ns-to` **per collection**, into a scratch db name:
```bash
docker exec pbm-agent pbm restore --time="2026-10-02T03:15:00" \
  --ns-from="reportify.patients" --ns-to="restoretest.patients" --yes
```
Repeat the `--ns-from`/`--ns-to` pair once per collection you want to check. This only works
within the *same* cluster the backup came from — PBM matches backups/PITR chunks to a replica
set's internal identity, not just its name, so restoring into a separate/fresh replica set (even
one named `rs0` too) does not make PITR chunks visible there; only a full named-snapshot restore
works cross-cluster, which is the right tool for genuine disaster recovery onto new
infrastructure, not for a safe same-cluster test.

### Monthly restore test — MongoDB (PBM / PITR)

1. Pick a timestamp from the last few hours (not "latest" — the point is to prove you can land on
   an arbitrary moment, which is the whole value of PITR over discrete dumps).
2. Pick 1-2 representative collections and restore each with `--ns-from`/`--ns-to` into a
   `restoretest` scratch db, as above.
3. Confirm document counts/content match what you'd expect as of that timestamp, and that the
   live collections were untouched.
4. **Resume PITR** (see the warning above — restore always disables it and requires a fresh
   backup, not just a config toggle, to actually resume): run `pbm-daily-backup.sh`, confirm
   `pbm status` shows no error and a new chunk actually appears after waiting ~70s.
5. Clean up: `docker exec mongodb mongosh ... --eval 'db.getSiblingDB("restoretest").dropDatabase()'`

### Health monitoring

`check-pbm-health.sh` runs via host cron every ~15 min, checks PITR chunk staleness + last base
backup status, and POSTs to the "Backup Health Alert" n8n workflow (Telegram) on failure. Fill in
`ALERT_WEBHOOK_URL` and `ALERT_SECRET_VALUE` at the top of the script, then:
```bash
chmod +x /root/scripts/db-backup/check-pbm-health.sh
crontab -e
```
Add:
```
*/15 * * * * /root/scripts/db-backup/check-pbm-health.sh
```

---

## Schedule reference

`0 */4 * * *` = har 4 ghante, minute 0 par (UTC):
```
00:00  04:00  08:00  12:00  16:00  20:00   (UTC)
```
Frequency badalni ho:
- Har 2 ghante:  `0 */2 * * *`
- Har ghante:    `0 * * * *`
- Har 30 min:    `*/30 * * * *`

---

## Restore — zaroorat padne par

### MongoDB restore (LEGACY — only applies before the PBM cutover below)
See "MongoDB backups (PBM)" above for the current restore procedure.
```bash
# R2 se backup laao
rclone copy r2:<BUCKET>/backups/ /tmp/restore/ --include "mongo_*" --max-age 6h
ls /tmp/restore/

# container mein bhejo
docker cp /tmp/restore/mongo_<STAMP>.archive mongodb:/tmp/rt.archive

# restore (asli DB overwrite karega — dhyan se; ya --nsTo se scratch db mein)
MU=$(docker exec mongodb printenv MONGO_INITDB_ROOT_USERNAME)
MP=$(docker exec mongodb printenv MONGO_INITDB_ROOT_PASSWORD)
docker exec mongodb mongorestore -u "$MU" -p "$MP" \
  --authenticationDatabase admin --gzip --archive=/tmp/rt.archive
```

### PostgreSQL restore (pg_dumpall = poora server)
```bash
rclone copy r2:<BUCKET>/backups/ /tmp/restore/ --include "pg_all_*" --max-age 6h

PU=$(docker exec postgres printenv POSTGRES_USER)
PP=$(docker exec postgres printenv POSTGRES_PASSWORD)
gunzip -c /tmp/restore/pg_all_<STAMP>.sql.gz | \
  docker exec -i -e PGPASSWORD="$PP" postgres psql -U "$PU"
```

---

## Monthly restore test (ZAROORI — mat bhoolna)

Bina test kiya backup = backup nahi. Mahine mein ek baar scratch DB mein restore
karke counts milao (asli DB safe rehta hai). **Mongo ab PBM se test hota hai** (see
"MongoDB backups (PBM)" above) — neeche wala Mongo example sirf pre-cutover legacy
reference ke liye hai.

```bash
# Mongo — LEGACY, pre-cutover — scratch db "restoretest" mein
rclone copy r2:<BUCKET>/backups/ /tmp/rtest/ --include "mongo_*" --max-age 6h
docker cp /tmp/rtest/mongo_*.archive mongodb:/tmp/rt.archive
MU=$(docker exec mongodb printenv MONGO_INITDB_ROOT_USERNAME)
MP=$(docker exec mongodb printenv MONGO_INITDB_ROOT_PASSWORD)
docker exec mongodb mongorestore -u "$MU" -p "$MP" --authenticationDatabase admin \
  --gzip --archive=/tmp/rt.archive --nsFrom='reportify.*' --nsTo='restoretest.*'
docker exec mongodb mongosh -u "$MU" -p "$MP" --authenticationDatabase admin \
  restoretest --quiet --eval 'db.getCollectionNames().forEach(c=>print(c, db.getCollection(c).countDocuments()))'
# counts asli reportify se milne chahiye. Phir:
docker exec mongodb mongosh -u "$MU" -p "$MP" --authenticationDatabase admin \
  --quiet --eval 'db.getSiblingDB("restoretest").dropDatabase()'
rm -rf /tmp/rtest
```

---

## Monitoring / checks

```bash
# Cron entry
crontab -l

# Backup log
tail -20 /var/log/backup.log

# Local backups
ls -lh /root/backups/

# R2 par kya pada hai
rclone ls r2:<BUCKET>/backups/

# R2 total size
rclone size r2:<BUCKET>/backups/
```

---

## Troubleshooting

| Problem | Wajah / Fix |
|---------|-------------|
| `database "reportify" does not exist` | `pg_dump -d` ka issue tha. Ab `pg_dumpall` use hota hai — naam ki zaroorat nahi. |
| `docker: command not found` (cron mein) | Cron ka PATH chhota. Script ke top par `export PATH=...` line hai — wahi fix hai. |
| `R2 upload FAIL` | rclone config / bucket naam / credentials check. `rclone lsd r2:` se test. |
| Postgres auth fail | Superuser ka naam `pguser` hai (not `postgres`). Auto-detect isko handle karta hai. |

For Mongo/PBM troubleshooting, see the "MongoDB backups (PBM)" section above — this script no
longer touches Mongo at all.

---

## Important notes

1. **R2 upload fail hona = sabse bada red flag.** Offsite copy hi poora point hai.
   Local backup server ke saath hi mar jaata hai. Log mein WARN dikhe to turant dekho.

2. **Atlas cluster** (agar abhi bhi hai) — ek-do hafte rakho jab tak ye backup
   verified na ho jaye. Free rollback.

3. **Restore test mat bhoolna** — mahine mein ek baar. Ye ek cheez hai jo log
   skip karte hain aur disaster ke waqt pachhtaate hain.

4. Redis backup ismein nahi hai (agar wo pure cache hai to zaroorat nahi).
   Agar Redis mein zaroori session/queue data ho to alag se `BGSAVE` + copy jodna.

---

## Cutover: Mongo removed from `backup-to-r2.sh` (done 2026-10-03)

The PBM validation gate (monthly-style restore test + artificial staleness alert) was run live on
production first — see "MongoDB backups (PBM)" above — and passed before this cutover happened,
per this project's "one system of record, not two running in parallel" decision. What changed:

1. `backup-to-r2.sh`'s whole "MongoDB backup" `if` block was deleted (not just disabled via a
   flag) — `BACKUP_POSTGRES="true"` and everything below it is untouched, same schedule.
2. Confirmed via the "Test (haath se)" step: output no longer mentions Mongo, still shows
   `Postgres dump OK` and `R2 upload OK`.
3. **Known follow-up (non-blocking):** `ReportifyPro/scripts/prune-mongo-backups.sh` and
   `restore-mongo-backup.sh` assumed new `mongo_*` archives would keep landing under the legacy R2
   `backups/` prefix — they won't anymore. That's fine (the prod→dev sync workflow they supported
   isn't actively used), but worth cleaning up or repointing at PBM eventually so a future reader
   doesn't trust a stale script.