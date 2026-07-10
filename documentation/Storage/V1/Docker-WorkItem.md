# Docker Work Item — Storage V1

**To:** Docker Team
**From:** Binoy
**Project:** Storage V1 — MinIO File Storage + Backup
**Priority:** High

---

## Context

We are introducing a platform-wide file storage service for BizFirst AI functions and
process nodes. Files uploaded by users or fetched from URLs are stored once (by content
hash), referenced by CID, and retrieved on demand. The storage engine is **MinIO** —
S3-compatible, self-hosted, runs entirely on our own Linux Docker infrastructure.

We also need a **backup process** (restic → Backblaze B2) running on a cron schedule.

Everything below needs to be added to the existing Docker Compose setup.

---

## Deliverable 1 — MinIO Container

Add a MinIO service to `docker-compose.yml`.

```yaml
services:

  minio:
    image: minio/minio:latest
    container_name: bizfirst-minio
    command: server /data --console-address ":9001"
    restart: unless-stopped
    volumes:
      - minio_data:/data
    environment:
      MINIO_ROOT_USER:     ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    ports:
      - "9000:9000"   # S3 API — used by the application
      - "9001:9001"   # MinIO Console UI — admin access
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - bizfirst-network
```

**Volume:**
```yaml
volumes:
  minio_data:
    driver: local
```

---

## Deliverable 2 — MinIO Bucket Initialisation

On first start, create the `bizfirst-files` bucket and set the access policy.
Use the MinIO Client (`mc`) as a one-shot init container.

```yaml
  minio-init:
    image: minio/mc:latest
    container_name: bizfirst-minio-init
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      mc alias set local http://minio:9000 $${MINIO_ROOT_USER} $${MINIO_ROOT_PASSWORD};
      mc mb --ignore-existing local/bizfirst-files;
      mc anonymous set none local/bizfirst-files;
      echo 'MinIO initialised';
      "
    networks:
      - bizfirst-network
    restart: "no"
```

---

## Deliverable 3 — Application Service — Environment Variables

The BizFirst application container needs these environment variables to connect to MinIO:

```yaml
  bizfirst-app:
    environment:
      FileStorage__Endpoint:       http://minio:9000
      FileStorage__AccessKey:      ${MINIO_APP_ACCESS_KEY}
      FileStorage__SecretKey:      ${MINIO_APP_SECRET_KEY}
      FileStorage__BucketName:     bizfirst-files
      FileStorage__Region:         us-east-1
      FileStorage__ForcePathStyle: "true"
      FileStorage__PrependTenantId: "false"
```

The app uses `ForcePathStyle=true` — this is required for MinIO (not needed for AWS S3).

---

## Deliverable 4 — Dedicated Application User (MinIO)

Do not use the root MinIO credentials in the application. Create a dedicated app user
with restricted permissions via the MinIO Console (port 9001) or via `mc`:

```bash
mc admin user add local bizfirst-app ${MINIO_APP_SECRET_KEY}
mc admin policy attach local readwrite --user bizfirst-app
```

The root credentials (`MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`) are for admin only.
The app credentials (`MINIO_APP_ACCESS_KEY` / `MINIO_APP_SECRET_KEY`) go into the app
environment variables.

---

## Deliverable 5 — Backup Container (restic → Backblaze B2)

Add a restic backup service that runs daily via cron.

```yaml
  minio-backup:
    image: restic/restic:latest
    container_name: bizfirst-minio-backup
    depends_on:
      - minio
    volumes:
      - minio_data:/data:ro          # read-only access to MinIO data
      - restic_cache:/root/.cache/restic
    environment:
      RESTIC_REPOSITORY: s3:s3.us-west-004.backblazeb2.com/${B2_BUCKET_NAME}
      RESTIC_PASSWORD:   ${RESTIC_PASSWORD}
      AWS_ACCESS_KEY_ID: ${B2_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${B2_APP_KEY}
    entrypoint: >
      /bin/sh -c "
      restic snapshots || restic init;
      restic backup /data;
      restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune;
      "
    restart: "no"
    networks:
      - bizfirst-network
```

**Schedule via host cron** (runs at 2am daily):
```cron
0 2 * * * docker compose -f /path/to/docker-compose.yml run --rm minio-backup
```

Or use a cron-capable sidecar image if host cron is not available.

**Restore command (when needed):**
```bash
docker compose run --rm minio-backup restic restore latest --target /restore
```

---

## Deliverable 6 — Environment Variables File (`.env`)

Add these to the `.env` file. **Secrets must be set securely — do not commit values.**

```env
# MinIO root admin credentials
MINIO_ROOT_USER=bizfirst-admin
MINIO_ROOT_PASSWORD=<set-strong-password>

# MinIO app credentials (used by BizFirst application)
MINIO_APP_ACCESS_KEY=bizfirst-app
MINIO_APP_SECRET_KEY=<set-strong-password>

# Backblaze B2 backup credentials
B2_BUCKET_NAME=bizfirst-backup
B2_KEY_ID=<backblaze-key-id>
B2_APP_KEY=<backblaze-app-key>

# restic encryption password (store safely — needed for restore)
RESTIC_PASSWORD=<set-strong-password>
```

---

## Deliverable 7 — Network

Ensure MinIO is on the same Docker network as the application container.

```yaml
networks:
  bizfirst-network:
    driver: bridge
```

The app connects to MinIO via `http://minio:9000` (internal Docker network — not exposed
to the public internet). Port 9000 is only published for admin access if needed.

---

## Summary of Deliverables

| # | Deliverable | Notes |
|---|-------------|-------|
| 1 | MinIO container in docker-compose.yml | With volume + healthcheck |
| 2 | MinIO bucket init container | Creates `bizfirst-files` bucket on first start |
| 3 | App container env vars for MinIO | Endpoint, credentials, bucket, ForcePathStyle |
| 4 | Dedicated MinIO app user | Restricted permissions — not root |
| 5 | Backup container (restic → B2) | Daily cron, 7-day retention |
| 6 | `.env` file entries | All secrets — do not commit values |
| 7 | Docker network config | MinIO + app on same internal network |

---

## Ports Summary

| Port | Service | Access |
|------|---------|--------|
| 9000 | MinIO S3 API | Internal (app → minio) |
| 9001 | MinIO Console UI | Admin only — restrict to VPN/internal |

---

## Questions for Docker Team

1. Is there an existing secrets management approach (Vault, Docker secrets, env file)?
2. Is host cron available for the backup schedule, or should we use a cron sidecar?
3. What is the available disk size for the MinIO volume?
4. Is there an existing Docker network the app uses that MinIO should join?
