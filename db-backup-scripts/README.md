# Database Backup Setup — Navexra Infra

MongoDB + PostgreSQL ka automated backup, Cloudflare R2 (offsite) par.
Local dumps bante hain, R2 par upload hote hain, purane apne aap delete hote hain.

---

## Overview

| Cheez | Detail |
|-------|--------|
| Kya backup hota hai | MongoDB (saari DB) + PostgreSQL (saara server, `pg_dumpall`) |
| Kahan jaata hai | Local `/root/backups` + Cloudflare R2 (offsite) |
| Kitni baar | Har 4 ghante (`0 */4 * * *`) — din mein 6 baar |
| Local retention | 3 din |
| R2 retention | 30 din |
| Server time | UTC |

**Design note:** Databases Dokploy ke bahar, apni `docker-compose.yml` se chalte hain.
Isliye backup bhi Dokploy ke bahar, in scripts se hota hai (Dokploy ka built-in
DB-backup in external databases ko nahi dekhta).

---

## Files

```
/root/scripts/db-backup/
├── setup-r2.sh        # ek baar: rclone install + R2 configure
├── backup-to-r2.sh    # rozana (cron): dump + upload + cleanup
└── README-backup.md   # ye file
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
Mongo dump OK: 27M
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

### MongoDB restore
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
karke counts milao (asli DB safe rehta hai):

```bash
# Mongo — scratch db "restoretest" mein
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
| Mongo dump khaali | Container naam ya credentials galat. `docker exec mongodb printenv MONGO_INITDB_ROOT_USERNAME` |
| Postgres auth fail | Superuser ka naam `pguser` hai (not `postgres`). Auto-detect isko handle karta hai. |

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