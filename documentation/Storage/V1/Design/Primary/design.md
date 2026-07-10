# Primary Storage — Design

## Responsibility

Provide a platform-wide, tenant-partitioned, content-addressable file storage service.
Implemented on top of MinIO (S3-compatible, self-hosted on Linux Docker).

---

## Foundational Project Stack

```
BizFirst.Integration.S3.Domain                     (existing — modified: add ServiceURL, ForcePathStyle)
  └── BizFirst.Integration.S3.Services             (existing — modified: _CreateClient(), DownloadStreamAsync, ExistsAsync)
        └── BizFirst.Ai.InfraHub.Storage     (new — implements IObjectStorageProvider)
              ← BizFirst.Ai.InfraHub.Storage.Domain   (new — defines IObjectStorageProvider)
              ← BizFirst.Ai.AiSession.Domain                (existing — IAiSessionContextAccessor)
```

These are foundational projects. Octopus consumes them — they are not aware of Octopus.
No `BizFirst.Ai.Octopus.*` project is modified.

---

## Modified Project — `BizFirst.Integration.S3.Domain`

### `S3Credential` — add `ServiceURL` and `ForcePathStyle`

The existing record only carries `AccessKeyID`, `SecretKey`, `SessionToken`, `Region`.
MinIO requires a custom `ServiceURL` and `ForcePathStyle = true`. Both fields are
optional with safe defaults — no existing callers break.

```csharp
// BizFirst.Integration.S3.Domain\Common\S3Credential.cs
public sealed record S3Credential(
    string  AccessKeyID,
    string  SecretKey,
    string? SessionToken,
    string  Region,
    string? ServiceURL     = null,   // null = standard AWS endpoint
    bool    ForcePathStyle = false   // true required for MinIO
);
```

### `S3ObjectDownloadStreamResult` — new result record (Finding 3)

```csharp
// BizFirst.Integration.S3.Domain\Object\S3ObjectDownloadStreamResult.cs
public sealed record S3ObjectDownloadStreamResult(
    bool    Success,
    string  Status,
    Stream? ResponseStream,
    long    Size,
    string? ETag,
    string  ErrorCode,
    string  ErrorMessage
)
{
    public static S3ObjectDownloadStreamResult Ok(Stream stream, long size, string? eTag)
        => new(true, "OK", stream, size, eTag, string.Empty, string.Empty);

    public static S3ObjectDownloadStreamResult Fail(string errorCode, string message)
        => new(false, "FAIL", null, 0, null, errorCode, message);
}
```

---

## Modified Project — `BizFirst.Integration.S3.Services`

### `_CreateClient()` — updated in all three services (Finding 2)

The existing method only sets `RegionEndpoint`, which fails for MinIO. Updated to
check `ServiceURL` first:

```csharp
// Apply this change to S3ObjectService, S3BucketService, S3FolderService
private AmazonS3Client _CreateClient(S3Credential cred)
{
    var config = new AmazonS3Config
    {
        Timeout       = TimeSpan.FromSeconds(60),
        MaxErrorRetry = 3
    };

    if (!string.IsNullOrWhiteSpace(cred.ServiceURL))
    {
        config.ServiceURL     = cred.ServiceURL;
        config.ForcePathStyle = cred.ForcePathStyle;
    }
    else
    {
        config.RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(cred.Region);
    }

    return new AmazonS3Client(
        new BasicAWSCredentials(cred.AccessKeyID, cred.SecretKey),
        config);
}
```

### `DownloadStreamAsync` — new method on `IS3ObjectService` (Finding 3)

The existing `DownloadAsync` writes to a `LocalFilePath` on disk. `GetStreamAsync` on
`IObjectStorageProvider` requires a live `Stream` without disk I/O.

```csharp
// New request record
// BizFirst.Integration.S3.Services\Object\Requests\ObjectDownloadStreamRequest.cs
public sealed record ObjectDownloadStreamRequest(
    string  BucketName,
    string  Region,
    string  ObjectKey,
    string? VersionId = null
);
```

```csharp
// BizFirst.Integration.S3.Services\Object\Interfaces\IS3ObjectService.cs — add method
Task<S3ObjectDownloadStreamResult> DownloadStreamAsync(
    ObjectDownloadStreamRequest req,
    S3Credential                cred,
    CancellationToken           ct = default);
```

```csharp
// S3ObjectService.cs — implementation
public async Task<S3ObjectDownloadStreamResult> DownloadStreamAsync(
    ObjectDownloadStreamRequest req,
    S3Credential                cred,
    CancellationToken           ct = default)
{
    try
    {
        using var client = _CreateClient(cred);
        var response = await client.GetObjectAsync(req.BucketName, req.ObjectKey, ct);
        return S3ObjectDownloadStreamResult.Ok(
            response.ResponseStream,
            response.ContentLength,
            response.ETag);
    }
    catch (AmazonS3Exception ex)
    {
        return S3ObjectDownloadStreamResult.Fail(ex.ErrorCode, ex.Message);
    }
}
```

---

## New Project — `BizFirst.Ai.InfraHub.Storage.Domain`

**Path:** `BizFirstPayrollV3\src\mvc-server\InfraHub\BizFirst.Ai.InfraHub.Storage.Domain\`

This project defines the public contract. It has no dependency on S3, Octopus, or AiSession.

### `StoreOptions`

Per-request overrides. All fields are optional — `null` means use the global
`FileStorageSettings` default. Callers that do not need overrides pass nothing.

```csharp
// BizFirst.Ai.InfraHub.Storage.Domain\StoreOptions.cs
namespace BizFirst.Ai.InfraHub.Storage.Domain;

public sealed record StoreOptions(
    string? CannedAcl    = null,   // null = use FileStorageSettings.CannedAcl
    string? StorageClass = null    // null = use FileStorageSettings.StorageClass
);
```

### `IObjectStorageProvider`

```csharp
// BizFirst.Ai.InfraHub.Storage.Domain\IObjectStorageProvider.cs
namespace BizFirst.Ai.InfraHub.Storage.Domain;

public interface IObjectStorageProvider
{
    /// <summary>
    /// Stores a file. Returns CID. Deduplicates within tenant.
    /// Pass <paramref name="options"/> to override per-request ACL or storage class.
    /// </summary>
    Task<string> StoreAsync(Stream        stream,
                            string?       fileName,
                            string?       mimeType,
                            StoreOptions? options = null,
                            CancellationToken ct  = default);

    /// <summary>Retrieves a file stream by CID for the current tenant.</summary>
    Task<Stream> GetStreamAsync(string cid, CancellationToken ct = default);

    /// <summary>Checks if a CID exists for the current tenant.</summary>
    Task<bool> ExistsAsync(string cid, CancellationToken ct = default);
}
```

### `StorageCapacityException`

```csharp
// BizFirst.Ai.InfraHub.Storage.Domain\StorageCapacityException.cs
namespace BizFirst.Ai.InfraHub.Storage.Domain;

public class StorageCapacityException : Exception
{
    public StorageCapacityException(string message) : base(message) { }
}
```

**Note:** `ITenantContextService` is not created. `S3ObjectStorageProvider` injects
`IAiSessionContextAccessor` directly from `BizFirst.Ai.AiSession.Domain` and reads
`.CurrentRequestSession.TenantID`. No wrapper interface is needed.

---

## New Project — `BizFirst.Ai.InfraHub.Storage`

**Path:** `BizFirstPayrollV3\src\mvc-server\InfraHub\BizFirst.Ai.InfraHub.Storage\`

### Project references

```
BizFirst.Ai.InfraHub.Storage
  → BizFirst.Ai.InfraHub.Storage.Domain  (WI-03)
  → BizFirst.Integration.S3.Services           (WI-02)
  → BizFirst.Integration.S3.Domain             (WI-01)
  → BizFirst.Ai.AiSession.Domain               (existing — IAiSessionContextAccessor)
```

No reference to `BizFirst.Ai.Octopus.*`.

### `S3ObjectStorageProvider`

```csharp
public class S3ObjectStorageProvider : IObjectStorageProvider
{
    private readonly IS3ObjectService         _objects;
    private readonly FileStorageSettings      _settings;
    private readonly IAiSessionContextAccessor _session;
    private readonly IHttpClientFactory       _httpClientFactory;
    private readonly ILogger<S3ObjectStorageProvider> _logger;

    public async Task<string> StoreAsync(
        Stream stream, string? fileName, string? mimeType,
        StoreOptions? options = null,
        CancellationToken ct  = default)
    {
        await EnforceDiskCapacityGuardAsync(ct);

        using var ms = new MemoryStream();
        await stream.CopyToAsync(ms, ct);
        var bytes = ms.ToArray();

        var hash      = ComputeSha256Hex(bytes);
        var tenantID  = _session.CurrentRequestSession.TenantID;
        var cid       = _settings.PrependTenantID ? $"{tenantID}_{hash}" : hash;
        var key       = $"tenant_{tenantID}/{cid}";
        var cred      = BuildCredential();

        var exists = await _objects.ExistsAsync(
            new ObjectExistsRequest(_settings.BucketName, _settings.Region, key), cred, ct);

        if (!exists.Success || !exists.Exists)
        {
            // options?.CannedAcl / StorageClass override FileStorageSettings defaults
            var cannedAcl    = options?.CannedAcl    ?? _settings.CannedAcl;
            var storageClass = options?.StorageClass ?? _settings.StorageClass;

            await _objects.UploadAsync(new ObjectUploadRequest(
                BucketName:          _settings.BucketName,
                Region:              _settings.Region,
                ObjectKey:           key,
                FileContent:         bytes,
                ContentType:         mimeType ?? "application/octet-stream",
                StorageClass:        storageClass,
                ServerSideEncryption: string.Empty,
                KmsKeyId:            null,
                CannedAcl:           cannedAcl,
                Metadata:            null,
                Tagging:             null), cred, ct);

            _logger.LogInformation("Stored file cid={Cid} tenant={TenantID} name={Name}",
                cid, tenantID, fileName);
        }
        else
        {
            _logger.LogDebug("Dedup hit cid={Cid} tenant={TenantID}", cid, tenantID);
        }

        return cid;
    }

    public async Task<Stream> GetStreamAsync(string cid, CancellationToken ct = default)
    {
        var tenantID = _session.CurrentRequestSession.TenantID;
        var key      = $"tenant_{tenantID}/{cid}";
        var result   = await _objects.DownloadStreamAsync(
            new ObjectDownloadStreamRequest(_settings.BucketName, _settings.Region, key),
            BuildCredential(), ct);

        if (!result.Success || result.ResponseStream is null)
            throw new InvalidOperationException(
                $"Failed to retrieve cid={cid}: {result.ErrorMessage}");

        return result.ResponseStream;
    }

    public async Task<bool> ExistsAsync(string cid, CancellationToken ct = default)
    {
        var tenantID = _session.CurrentRequestSession.TenantID;
        var key      = $"tenant_{tenantID}/{cid}";
        var result   = await _objects.ExistsAsync(
            new ObjectExistsRequest(_settings.BucketName, _settings.Region, key),
            BuildCredential(), ct);
        return result.Success && result.Exists;
    }

    private S3Credential BuildCredential() => new(
        AccessKeyID:    _settings.AccessKey,
        SecretKey:      _settings.SecretKey,
        SessionToken:   null,
        Region:         _settings.Region,
        ServiceURL:     string.IsNullOrWhiteSpace(_settings.Endpoint) ? null : _settings.Endpoint,
        ForcePathStyle: _settings.ForcePathStyle);

    private static string ComputeSha256Hex(byte[] bytes)
    {
        var hash = SHA256.HashData(bytes);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }
}
```

### Disk capacity guard

```csharp
private async Task EnforceDiskCapacityGuardAsync(CancellationToken ct)
{
    if (_settings.WriteStopThresholdPercent <= 0) return;

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
    var client   = _httpClientFactory.CreateClient();
    var response = await client.GetStringAsync(
        $"{_settings.Endpoint}/minio/v2/metrics/cluster", ct);
    var used  = ParseMetric(response, "minio_node_disk_used_bytes");
    var total = ParseMetric(response, "minio_node_disk_total_bytes");
    return total > 0 ? (used / total) * 100.0 : 0.0;
}
```

### `FileStorageSettings`

```csharp
public class FileStorageSettings
{
    public string BucketName                { get; set; } = "bizfirst-files";
    public string Endpoint                  { get; set; } = string.Empty;  // blank = AWS S3
    public string AccessKey                 { get; set; } = string.Empty;
    public string SecretKey                 { get; set; } = string.Empty;
    public string Region                    { get; set; } = "us-east-1";
    public bool   ForcePathStyle            { get; set; } = true;
    public bool   PrependTenantID           { get; set; } = false;
    public double WriteStopThresholdPercent { get; set; } = 90.0;

    /// <summary>Default ACL for all uploads. Can be overridden per-request via StoreOptions.</summary>
    public string CannedAcl    { get; set; } = "NoACL";

    /// <summary>Default storage class for all uploads. Can be overridden per-request via StoreOptions.</summary>
    public string StorageClass { get; set; } = "STANDARD";
}
```

### `StorageCapacityException`

```csharp
public class StorageCapacityException : Exception
{
    public StorageCapacityException(string message) : base(message) { }
}
```

### `FileStorageDependencyInjection`

```csharp
public static class FileStorageDependencyInjection
{
    public static IServiceCollection AddObjectStorage(
        this IServiceCollection services,
        IConfiguration          config)
    {
        services.Configure<FileStorageSettings>(config.GetSection("FileStorage"));
        services.AddHttpClient();
        services.AddS3Services();
        services.AddScoped<IObjectStorageProvider, S3ObjectStorageProvider>();
        return services;
    }
}
```

---

## CID Design

### Computation

```
CID = SHA-256(fileBytes) as lowercase hex string
```

### Storage Key

```
key = tenant_{tenantID}/{cid}
```

### `PrependTenantID` Option (default: false)

| Setting | CID | Key |
|---------|-----|-----|
| `false` | `bafybeig3x...` | `tenant_42/bafybeig3x...` |
| `true` | `42_bafybeig3x...` | `tenant_42/42_bafybeig3x...` |

`true` prevents cross-tenant content inference from CID values alone.
Storage is always tenant-partitioned regardless of this setting.

### Deduplication

Same file uploaded twice by the same tenant → same CID → object exists check returns true
→ write skipped → CID returned. One stored copy per tenant.

---

## Logging Safety

| Logged | Not Logged |
|--------|-----------|
| `cid` | Raw bytes |
| `tenantID` | Stream contents |
| `fileName` | |
| `mimeType` | |

---

## Compatible Storage Backends

The same `S3ObjectStorageProvider` code works against any S3-compatible backend.
Only `FileStorageSettings.Endpoint` and `ForcePathStyle` change.

| Backend | Endpoint | ForcePathStyle | Cost |
|---------|----------|----------------|------|
| MinIO (self-hosted) | `http://minio:9000` | `true` | Own disk |
| AWS S3 | _(blank)_ | `false` | ~$0.023/GB/month |
| Cloudflare R2 | R2 endpoint | `false` | ~$0.015/GB, no egress |
| Backblaze B2 | B2 S3 endpoint | `false` | ~$0.006/GB/month |

Azure Blob Storage does **not** support the S3 API — not a compatible backend.

---

## Environment Configuration

The same `S3ObjectStorageProvider` code runs in all environments. Only `FileStorageSettings`
changes per environment.

### Windows / IIS (local development)

MinIO has a native Windows binary — no Docker required. Run it as a local process
or install as a Windows Service.

```powershell
# Run MinIO on Windows
.\minio.exe server C:\bizfirst-storage --console-address ":9001"
```

```json
// appsettings.Development.json
{
  "FileStorage": {
    "Endpoint":       "http://localhost:9000",
    "AccessKey":      "minioadmin",
    "SecretKey":      "minioadmin",
    "BucketName":     "bizfirst-files",
    "Region":         "us-east-1",
    "ForcePathStyle": true
  }
}
```

### Linux Docker (production)

```json
// appsettings.Production.json (or env vars)
{
  "FileStorage": {
    "Endpoint":       "http://minio:9000",
    "AccessKey":      "${MINIO_APP_ACCESS_KEY}",
    "SecretKey":      "${MINIO_APP_SECRET_KEY}",
    "BucketName":     "bizfirst-files",
    "Region":         "us-east-1",
    "ForcePathStyle": true
  }
}
```

### Cloud S3 / R2 / B2 (if migrating away from self-hosted)

```json
{
  "FileStorage": {
    "Endpoint":       "",        // blank = AWS S3; or R2/B2 endpoint URL
    "AccessKey":      "...",
    "SecretKey":      "...",
    "BucketName":     "bizfirst-files",
    "Region":         "us-east-1",
    "ForcePathStyle": false      // false for AWS S3 / R2 / B2
  }
}
```

No code changes across any environment — only config.

---

## Project Dependencies

```
BizFirst.Integration.S3.Domain                    (no dependencies)
  (AWSSDK.S3, AWSSDK.Core)

BizFirst.Integration.S3.Services
  → BizFirst.Integration.S3.Domain

BizFirst.Ai.AiSession.Domain                      (existing — no changes)
  (defines IAiSessionContextAccessor)

BizFirst.Ai.InfraHub.Storage.Domain         (new — no dependencies)
  (defines IObjectStorageProvider, StorageCapacityException)

BizFirst.Ai.InfraHub.Storage                (new)
  → BizFirst.Ai.InfraHub.Storage.Domain
  → BizFirst.Integration.S3.Services
  → BizFirst.Integration.S3.Domain
  → BizFirst.Ai.AiSession.Domain
```
