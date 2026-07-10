# Hot Standby — Design

## Responsibility

Maintain a live replica of the primary MinIO instance so that storage remains available
if the primary fails. Failover is near-immediate — no restore from backup required.

---

## Approach — MinIO Bucket Replication

MinIO supports active-passive bucket replication. Every write to the primary bucket is
asynchronously replicated to a secondary MinIO instance.

```
Primary MinIO (minio-primary)
  bucket: bizfirst-files
       │
       │  async replication
       ▼
Secondary MinIO (minio-secondary)
  bucket: bizfirst-files-replica
```

---

## Docker Setup

```yaml
services:

  minio-primary:
    image: minio/minio:latest
    container_name: bizfirst-minio-primary
    command: server /data --console-address ":9001"
    volumes:
      - minio_primary_data:/data
    environment:
      MINIO_ROOT_USER:     ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    ports:
      - "9000:9000"
      - "9001:9001"
    networks:
      - bizfirst-network

  minio-secondary:
    image: minio/minio:latest
    container_name: bizfirst-minio-secondary
    command: server /data --console-address ":9003"
    volumes:
      - minio_secondary_data:/data
    environment:
      MINIO_ROOT_USER:     ${MINIO_SECONDARY_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_SECONDARY_PASSWORD}
    ports:
      - "9002:9000"
      - "9003:9001"
    networks:
      - bizfirst-network

volumes:
  minio_primary_data:
  minio_secondary_data:
```

---

## Replication Configuration

```bash
# Configure primary → secondary replication
mc alias set primary   http://minio-primary:9000   $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
mc alias set secondary http://minio-secondary:9000 $MINIO_SECONDARY_USER $MINIO_SECONDARY_PASSWORD

# Create replica bucket on secondary
mc mb secondary/bizfirst-files-replica

# Enable replication on primary bucket
mc replicate add primary/bizfirst-files \
  --remote-bucket  bizfirst-files-replica \
  --remote-address http://minio-secondary:9000 \
  --access-key     ${MINIO_SECONDARY_USER} \
  --secret-key     ${MINIO_SECONDARY_PASSWORD} \
  --replicate      "delete,delete-marker,existing-objects"
```

---

## Failover Procedure

1. Update `FileStorage__Endpoint` in the application env from `http://minio-primary:9000`
   to `http://minio-secondary:9000`
2. Restart the application container
3. All reads and writes now go to the secondary

```bash
# Update env and restart
export FileStorage__Endpoint=http://minio-secondary:9000
docker compose up -d bizfirst-app
```

---

## Cost

| Resource | Cost |
|----------|------|
| Second MinIO container | Same server = CPU/memory overhead only |
| Second disk volume | 2× storage cost |
| Replication traffic | Internal network = free |

---

## Replication Lag

Replication is asynchronous. Under normal load, lag is sub-second. Under heavy write load,
lag may increase. For disaster recovery (primary disk failure), some recent objects may
not yet be replicated.

For zero data loss, combine with `Backup/design.md` (restic snapshots).

---

## Related

- `Backup/design.md` — restic backup covers data not yet replicated
- `Primary/design.md` — primary storage configuration
