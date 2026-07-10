# Backup — Design

## Responsibility

Provide daily automated backup of MinIO file storage to Backblaze B2 cloud storage.
Backups are encrypted, deduplicated, and incremental. Point-in-time restore is available
for up to 12 months.

---

## Tool — restic

**restic** is an open-source backup tool. It is:
- Content-addressable (same data backed up once — dedup)
- Encrypted at rest (AES-256-CTR, Poly1305-AES)
- Incremental (only changed data transferred each run)
- Backend-agnostic (supports Backblaze B2, AWS S3, local, SFTP, and more)

Because MinIO stores files by CID (content hash), restic's own deduplication compounds
with the storage layer — the backup is highly space-efficient.

---

## Backup Target — Backblaze B2

| Property | Value |
|----------|-------|
| Cost | ~$0.006/GB/month |
| Egress | $0.01/GB (low) |
| S3-compatible API | Yes |
| Durability | 99.999999% |
| restic support | Native (via S3-compatible API) |

---

## Retention Policy

| Snapshot type | Kept |
|---------------|------|
| Daily | Last 7 |
| Weekly | Last 4 |
| Monthly | Last 12 |
Annual | Last 2

Snapshots older than retention policy are pruned automatically after each backup run.

---

## Docker Setup

```yaml
services:

  minio-backup:
    image: restic/restic:latest
    container_name: bizfirst-minio-backup
    depends_on:
      - minio
    volumes:
      - minio_data:/data:ro              # read-only MinIO data volume
      - restic_cache:/root/.cache/restic # restic local cache for speed
    environment:
      RESTIC_REPOSITORY: s3:s3.us-west-004.backblazeb2.com/${B2_BUCKET_NAME}
      RESTIC_PASSWORD:   ${RESTIC_PASSWORD}
      AWS_ACCESS_KEY_ID: ${B2_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${B2_APP_KEY}
    entrypoint: >
      /bin/sh -c "
      restic snapshots 2>/dev/null || restic init;
      restic backup /data --tag bizfirst;
      restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune;
      restic check;
      "
    restart: "no"
    networks:
      - bizfirst-network

volumes:
  restic_cache:
```

---

## Schedule

Run as a daily cron job at 02:00 (off-peak):

```cron
0 2 * * * docker compose -f /opt/bizfirst/docker-compose.yml run --rm minio-backup
```

---

## Environment Variables Required

```env
B2_BUCKET_NAME=bizfirst-backup-prod
B2_KEY_ID=<backblaze-key-id>
B2_APP_KEY=<backblaze-application-key>
RESTIC_PASSWORD=<strong-encryption-password>  # store safely — required for restore
```

**Critical:** `RESTIC_PASSWORD` must be stored securely and independently.
If lost, backups cannot be restored.

---

## Verification

restic runs `restic check` after each backup to verify repository integrity.
Output is logged by Docker for monitoring.

---

## Related

- See `PointInTimeRestore/design.md` for restore procedures
- See `Docker-WorkItem.md` for full Docker team deliverables
