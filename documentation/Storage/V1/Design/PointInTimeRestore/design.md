# Point-In-Time Restore — Design

## Responsibility

Enable recovery of any file or the full storage volume to a specific point in time
using restic snapshots stored in Backblaze B2.

---

## Restore Capabilities

| What | How |
|------|-----|
| Single file | `restic restore --include /data/tenant_X/cid` |
| Full tenant partition | `restic restore --include /data/tenant_X/` |
| Full storage volume | `restic restore latest --target /restore` |
| Specific point in time | `restic restore <snapshot-id> --target /restore` |

---

## Listing Snapshots

```bash
# List all snapshots
docker compose run --rm minio-backup restic snapshots

# Output example:
# ID        Time                 Host    Tags       Paths
# abc12345  2026-05-20 02:00:01  docker  bizfirst   /data
# def67890  2026-05-19 02:00:00  docker  bizfirst   /data
# ...
```

---

## Restore Procedures

### Full Volume Restore

```bash
# Restore latest snapshot to /restore on host
docker compose run --rm \
  -v /restore:/restore \
  minio-backup \
  restic restore latest --target /restore

# Then copy restored data back into MinIO volume
docker compose stop minio
cp -r /restore/data/* /var/lib/docker/volumes/bizfirst_minio_data/_data/
docker compose start minio
```

### Single Tenant Restore

```bash
docker compose run --rm \
  -v /restore:/restore \
  minio-backup \
  restic restore latest --include "/data/tenant_42/" --target /restore
```

### Restore to Specific Date

```bash
# Find snapshot closest to target date
docker compose run --rm minio-backup restic snapshots --tag bizfirst

# Restore that snapshot by ID
docker compose run --rm \
  -v /restore:/restore \
  minio-backup \
  restic restore abc12345 --target /restore
```

---

## Recovery Time Objective (RTO)

| Scope | Estimated RTO |
|-------|---------------|
| Single file | < 5 minutes |
| Single tenant | 15–30 minutes (depends on data size) |
| Full volume | 1–4 hours (depends on total storage size) |

RTO depends on Backblaze B2 download speed and total data volume.

---

## Recovery Point Objective (RPO)

Backups run daily at 02:00. Maximum data loss in a full failure scenario: **24 hours**.

To reduce RPO, increase backup frequency in the cron schedule.

---

## Related

- See `Backup/design.md` for backup setup and retention policy
