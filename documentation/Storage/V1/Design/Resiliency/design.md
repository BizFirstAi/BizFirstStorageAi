# Business Resiliency — Design

## Responsibility

Ensure the storage service remains operational, observable, and recoverable.
Provide early warnings before problems become outages. Define what happens to the
business when storage degrades, and how the system responds automatically or guides
operators to respond.

---

## Resiliency Concerns

| Concern | Risk | Response |
|---------|------|----------|
| Disk full | Writes fail — users cannot upload files | Alert at 70%, hard stop prevention at 90% |
| MinIO process crash | All reads and writes fail | Docker restart policy + health check |
| Disk I/O degradation | Slow uploads/downloads, timeouts | Metrics alert on latency threshold |
| Network partition | App cannot reach MinIO | Circuit breaker in S3FileStorageProvider |
| Corruption | Stored files unreadable | restic verify + MinIO bitrot protection |
| Runaway growth | Disk fills faster than expected | Lifecycle policy + capacity alert |

---

## Disk Space Monitoring

### MinIO Health Endpoints

MinIO exposes three HTTP health endpoints. No credentials required.

```
GET http://minio:9000/minio/health/live     → 200 = process alive
GET http://minio:9000/minio/health/ready    → 200 = ready to serve (includes disk check)
GET http://minio:9000/minio/health/cluster  → 200 = cluster healthy (distributed mode)
```

`/minio/health/ready` returns **503** when MinIO cannot serve requests — including when
disk is critically full. This is the endpoint Docker uses for the health check.

```yaml
# docker-compose.yml
minio:
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/ready"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 20s
```

---

### Capacity Alert Thresholds

| Level | Threshold | Action |
|-------|-----------|--------|
| Warning | 70% disk used | Notify ops team — plan capacity increase |
| Critical | 85% disk used | Urgent notification — immediate action required |
| Emergency | 95% disk used | Automatic: pause non-critical writes, alert all channels |

---

### MinIO Prometheus Metrics

MinIO exposes Prometheus-compatible metrics at `/minio/v2/metrics/cluster`.

Key metrics to monitor:

```
minio_node_disk_used_bytes          — bytes used per disk
minio_node_disk_total_bytes         — total capacity per disk
minio_node_disk_free_bytes          — free bytes per disk
minio_s3_requests_total             — request count by type
minio_s3_requests_errors_total      — error count
minio_node_disk_latency_us          — disk I/O latency
```

**Disk usage percentage:**
```promql
(minio_node_disk_used_bytes / minio_node_disk_total_bytes) * 100
```

**Prometheus alert rules:**

```yaml
groups:
  - name: bizfirst-storage
    rules:

      - alert: StorageDiskWarning
        expr: (minio_node_disk_used_bytes / minio_node_disk_total_bytes) * 100 > 70
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Storage disk above 70% — plan capacity increase"
          description: "Disk usage: {{ $value | printf \"%.1f\" }}%"

      - alert: StorageDiskCritical
        expr: (minio_node_disk_used_bytes / minio_node_disk_total_bytes) * 100 > 85
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Storage disk above 85% — immediate action required"

      - alert: StorageDiskEmergency
        expr: (minio_node_disk_used_bytes / minio_node_disk_total_bytes) * 100 > 95
        for: 1m
        labels:
          severity: emergency
        annotations:
          summary: "Storage disk above 95% — writes may be failing"

      - alert: StorageHighErrorRate
        expr: rate(minio_s3_requests_errors_total[5m]) > 0.05
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Storage error rate above 5% — investigate immediately"

      - alert: StorageDown
        expr: up{job="minio"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "MinIO is down — storage unavailable"
```

---

### MinIO Webhook Notifications (without Prometheus)

If Prometheus is not available, MinIO can send webhook notifications directly.

```bash
# Configure MinIO to call a webhook when storage events occur
mc admin config set myminio notify_webhook:alerts \
  endpoint="https://alerts.bizfirst.internal/minio" \
  auth_token="${ALERT_WEBHOOK_TOKEN}"

# Apply config
mc admin service restart myminio
```

---

### Simple Disk Check Script (lightweight option)

If no monitoring stack is available, run a cron-based disk check:

```bash
#!/bin/bash
# /opt/bizfirst/check-disk.sh
THRESHOLD=85
USAGE=$(df /var/lib/docker/volumes/bizfirst_minio_data | tail -1 | awk '{print $5}' | tr -d '%')

if [ "$USAGE" -gt "$THRESHOLD" ]; then
  curl -X POST "${SLACK_WEBHOOK_URL}" \
    -H 'Content-type: application/json' \
    -d "{\"text\": \":warning: BizFirst Storage disk at ${USAGE}% — action required\"}"
fi
```

```cron
*/15 * * * * /opt/bizfirst/check-disk.sh
```

---

## Application-Level Resiliency

### `S3FileStorageProvider` — Error Handling

When MinIO is unavailable or disk is full, `StoreFileAsync` should not crash the caller.
It should return a typed result or throw a domain exception the caller can handle.

```csharp
public async Task<StorageResult> TryStoreFileAsync(
    Stream stream, string? fileName, string? mimeType)
{
    try
    {
        var cid = await StoreFileAsync(stream, fileName, mimeType);
        return StorageResult.Ok(cid);
    }
    catch (AmazonS3Exception ex) when (ex.StatusCode == HttpStatusCode.ServiceUnavailable)
    {
        _logger.LogError("Storage unavailable — disk may be full. Error: {Msg}", ex.Message);
        return StorageResult.Fail(StorageErrorCode.StorageUnavailable, ex.Message);
    }
    catch (AmazonS3Exception ex) when (ex.ErrorCode == "NoSuchBucket")
    {
        _logger.LogError("Storage bucket missing. Error: {Msg}", ex.Message);
        return StorageResult.Fail(StorageErrorCode.BucketMissing, ex.Message);
    }
    catch (Exception ex)
    {
        _logger.LogError(ex, "Unexpected storage error for file '{Name}'", fileName);
        return StorageResult.Fail(StorageErrorCode.Unexpected, ex.Message);
    }
}
```

### Graceful Degradation

When storage writes fail, the platform should:

| Scenario | User experience | System action |
|----------|----------------|---------------|
| Disk full | "File upload temporarily unavailable" | Return `503` with retry hint |
| MinIO down | "Storage service unavailable" | Return `503`, log incident |
| Slow I/O | Upload times out | Configurable timeout in `FileStorageSettings` |
| CID lookup miss | "File not found" | Return `404`, log CID + tenantId |

---

## Capacity Planning

### Audio File Estimates

| Metric | Estimate |
|--------|----------|
| Average audio file size | 5 MB (compressed mp3, ~10 min) |
| Files per tenant per day | 50 (typical) |
| Tenants | 100 |
| Daily ingest | 50 × 100 × 5 MB = 25 GB/day |
| Monthly ingest | ~750 GB/month |
| With deduplication (est. 30% overlap) | ~525 GB/month net new |

Adjust these numbers for your actual tenant count and usage patterns.

### Disk Sizing Recommendation

| Period | Storage needed |
|--------|---------------|
| 30-day hot storage | ~750 GB |
| 90-day buffer | ~2.2 TB |
| 1-year with archival at Day 30 | ~1 TB hot + cold tier |

Provision at least **2× estimated need** to stay below the 70% warning threshold.

---

## Incident Response Runbook

### Disk Full (>95%)

1. Immediately run lifecycle policy to purge expired objects:
   ```bash
   mc ilm ls myminio/bizfirst-files   # verify rules are active
   mc admin heal myminio/bizfirst-files  # trigger scan + cleanup
   ```
2. Identify largest tenants:
   ```bash
   mc du myminio/bizfirst-files --depth 1
   ```
3. If lifecycle not enough — expand disk volume (cloud VM: attach larger EBS/disk)
4. Notify ops team of root cause and capacity increase plan

### MinIO Process Down

Docker `restart: unless-stopped` will auto-restart. If it does not come back:
1. Check logs: `docker logs bizfirst-minio --tail 100`
2. Check disk: `df -h`
3. Check permissions on volume: `ls -la /var/lib/docker/volumes/bizfirst_minio_data`
4. Manual restart: `docker compose restart minio`

### Corruption Detected

1. Run restic verify against latest backup:
   ```bash
   docker compose run --rm minio-backup restic check
   ```
2. Identify corrupted objects via MinIO heal:
   ```bash
   mc admin heal --recursive myminio/bizfirst-files
   ```
3. Restore specific objects from restic if needed (see `PointInTimeRestore/design.md`)

---

## Related Documents

- `Primary/design.md` — S3FileStorageProvider error handling
- `HotStandby/design.md` — live replica for availability
- `Backup/design.md` — restic for corruption recovery
- `PointInTimeRestore/design.md` — restore procedures
- `Archival/design.md` — lifecycle policies to manage disk usage
- `Docker-WorkItem.md` — Docker team health check and restart policy deliverables
