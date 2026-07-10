# Stop Writes at 90% Disk Capacity

## Decision

When disk usage reaches **90%**, the storage service must **reject all new writes**.
Existing files remain readable. Reads are never blocked.

This protects the operating system, MinIO metadata, and the backup process from competing
for the last available disk space — a scenario that causes data corruption and system
instability.

---

## Does MinIO Support This Natively?

**No.** MinIO does not have a native percentage-based write-stop threshold.

What MinIO does have:
- **Per-bucket hard quota** — stops writes when a bucket reaches a configured byte limit
- **Auto-stop at ~100%** — MinIO stops accepting writes when the disk is essentially full,
  but this is too late (OS and metadata are already starved)
- **No dynamic percentage threshold** — MinIO has no built-in "stop at 70% / 85% / 90%"
  configuration

**Enforcement is therefore done in two layers:**

1. **Bucket quota** (MinIO) — static byte ceiling calculated from disk capacity
2. **Application guard** (S3ObjectStorageProvider) — dynamic check against live disk usage
   before every write

Both layers are required. The bucket quota is a hard backstop. The application guard
provides the dynamic percentage behaviour and responds before the quota is hit.

---

## Layer 1 — MinIO Bucket Hard Quota

### What it does

Sets a hard maximum byte limit on the `bizfirst-files` bucket. When the limit is reached,
MinIO rejects writes with `XMinioStorageFull`. Reads are unaffected.

### How to calculate

```
quota_bytes = total_disk_bytes × 0.90
```

Example — 2 TB disk:
```
2,000,000,000,000 × 0.90 = 1,800,000,000,000 bytes  (1.8 TB)
```

### Apply quota

```bash
# Set hard quota on the bucket (bytes)
mc admin bucket quota myminio/bizfirst-files --hard 1800000000000

# Verify
mc admin bucket quota myminio/bizfirst-files
```

### Update quota when disk is expanded

When additional disk capacity is added, recalculate and update:

```bash
# Get new total disk size
df -B1 /var/lib/docker/volumes/bizfirst_minio_data | tail -1 | awk '{print $2}'

# Recalculate 90% and apply
mc admin bucket quota myminio/bizfirst-files --hard <new_quota_bytes>
```

### Limitation

The quota is a static byte value. It does not automatically adjust when disk is
expanded or when archival frees space. It must be updated manually after disk changes.
This is why Layer 2 is also required.

---

## Layer 2 — Application Guard in `S3ObjectStorageProvider`

### What it does

Before every write, the provider checks live disk usage via the MinIO admin metrics API.
If disk usage is at or above 90%, the write is rejected immediately with a typed error —
before any bytes are sent to MinIO.

### Implementation

```csharp
public async Task<string> StoreAsync(
    Stream stream, string? fileName, string? mimeType,
    CancellationToken ct = default)
{
    await EnforceDiskCapacityGuardAsync(ct);

    // ... rest of store logic
}

private async Task EnforceDiskCapacityGuardAsync(CancellationToken ct)
{
    var usage = await GetDiskUsagePercentAsync(ct);
    if (usage >= _settings.WriteStopThresholdPercent)
    {
        _logger.LogError(
            "Write rejected — disk at {Usage:F1}% (threshold {Threshold}%)",
            usage, _settings.WriteStopThresholdPercent);

        throw new StorageCapacityException(
            $"Storage write rejected: disk at {usage:F1}%. " +
            $"Threshold is {_settings.WriteStopThresholdPercent}%.");
    }
}

private async Task<double> GetDiskUsagePercentAsync(CancellationToken ct)
{
    // MinIO metrics endpoint — no auth required for health metrics
    var response = await _httpClient.GetStringAsync(
        $"{_settings.Endpoint}/minio/v2/metrics/cluster", ct);

    // Parse Prometheus text format
    // minio_node_disk_used_bytes and minio_node_disk_total_bytes
    var used  = ParseMetric(response, "minio_node_disk_used_bytes");
    var total = ParseMetric(response, "minio_node_disk_total_bytes");

    return total > 0 ? (used / total) * 100.0 : 0.0;
}
```

### `FileStorageSettings` — new field

```csharp
public class FileStorageSettings
{
    public string BucketName             { get; set; } = "bizfirst-files";
    public string Endpoint               { get; set; }
    public string AccessKey              { get; set; }
    public string SecretKey              { get; set; }
    public string Region                 { get; set; } = "us-east-1";
    public bool   ForcePathStyle         { get; set; } = true;
    public bool   PrependTenantID        { get; set; } = false;

    /// <summary>
    /// Reject writes when disk usage reaches this percentage.
    /// Default: 90. Set to 0 to disable the application-level guard.
    /// </summary>
    public double WriteStopThresholdPercent { get; set; } = 90.0;
}
```

### `StorageCapacityException`

```csharp
public class StorageCapacityException : Exception
{
    public StorageCapacityException(string message) : base(message) { }
}
```

Callers catch this and return `HTTP 507 Insufficient Storage` to the client.

---

## Caller Response — HTTP 507

When `StorageCapacityException` is thrown, the API layer returns:

```
HTTP 507 Insufficient Storage
{
  "error": "storage_capacity_exceeded",
  "message": "File upload temporarily unavailable. Storage capacity reached.",
  "retryAfter": null
}
```

Do NOT return details of the disk percentage to the client — that is internal operational
information.

---

## Combined Enforcement Flow

```
StoreAsync() called
       │
       ▼
Application guard: GetDiskUsagePercentAsync()
  ≥ 90%? → throw StorageCapacityException → HTTP 507 to caller
  < 90%? → continue
       │
       ▼
IS3ObjectService.UploadAsync()
       │
       ▼
MinIO checks bucket quota
  quota exceeded? → AmazonS3Exception (XMinioStorageFull) → HTTP 507 to caller
  quota ok?       → write succeeds → return CID
```

---

## Configuration Summary

| Setting | Where | Value |
|---------|-------|-------|
| `WriteStopThresholdPercent` | `FileStorageSettings` | `90.0` (default) |
| Bucket hard quota | MinIO (`mc admin bucket quota`) | disk_bytes × 0.90 |
| Warning alert | Prometheus / cron script | 70% |
| Critical alert | Prometheus / cron script | 85% |
| **Write stop** | Application guard + bucket quota | **90%** |
| MinIO auto-stop | MinIO internal | ~100% (fallback only) |

---

## Operational Notes

- When writes are stopped at 90%, reads continue normally. Users can still access
  previously uploaded files.
- The ops team has 10% headroom (90% → 100%) to respond before the system is
  completely full.
- The 85% critical alert (see `design.md`) gives the ops team a 5% advance warning
  before writes stop.
- After adding disk capacity, update the bucket quota and — if needed — adjust
  `WriteStopThresholdPercent` in config.
- `WriteStopThresholdPercent` can be set to `0` to disable the application guard
  in environments where MinIO's bucket quota is sufficient (e.g. development).

---

## Related

- `design.md` (Resiliency) — full alert thresholds and Prometheus rules
- `Primary/design.md` — `S3ObjectStorageProvider` and `FileStorageSettings`
- `Archival/design.md` — lifecycle policies to free disk space before threshold is hit
