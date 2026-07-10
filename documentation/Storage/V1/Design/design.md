# Storage V1 — Design Document

## Overview

BizFirst requires a platform-wide file storage service. Files may be uploaded by users
or downloaded from URLs. The storage service ensures:

- Files are stored **once** and referenced by CID (Content Addressable ID)
- Storage is always **tenant-partitioned**
- File content **never appears in logs or traces**
- The implementation is **S3-compatible** — runs on MinIO (self-hosted) or any S3 provider

Consumers (AI functions, process nodes) reference this service via `IObjectStorageProvider`.
How consumers transport and pass files is outside the scope of this project.

---

## Primary Storage — MinIO

**MinIO** is the chosen primary storage engine. Open-source, S3-compatible, runs as a
Docker container on the existing Linux infrastructure. No external service dependency,
no per-GB or per-request fees.

### Why MinIO

| Requirement | MinIO |
|-------------|-------|
| Self-hosted on Linux Docker | Yes |
| S3-compatible API | Yes — same code works for AWS S3, R2, B2 |
| No licensing fees | Yes — free for self-hosted internal use |
| No per-GB cost | Yes — uses your own disk |
| Production-grade | Yes — widely used at enterprise scale |
| .NET SDK available | Yes — AWSSDK.S3 (same SDK already in use) |

---

## Leveraging the Existing S3 Node

The platform already has a full S3 integration in:
```
BizFirstPayrollV3\src\mvc-server\AI\ExecutionNodes\Productivity\S3\
  BizFirst.Integration.S3.Services\
    IS3BucketService   — bucket operations
    IS3ObjectService   — upload, download, copy, delete, get-many
    IS3FolderService   — folder create, delete, list
  BizFirst.Integration.S3.Domain\
    S3Credential       — accessKeyId, secretKey, sessionToken, region
```

The `IS3ObjectService` and `AWSSDK.S3` (`AmazonS3Client`) already support custom endpoints.
**MinIO requires only two config changes** from the standard AWS S3 setup:

```csharp
new AmazonS3Config
{
    ServiceURL     = "http://minio:9000",   // MinIO container endpoint
    ForcePathStyle = true                   // required for MinIO
}
```

`S3ObjectStorageProvider` wraps `IS3ObjectService` internally. No new S3 client code is
written — the existing battle-tested integration is reused as-is.

```
IObjectStorageProvider                     ← defined in BizFirst.Ai.InfraHub.Storage.Domain
  └── S3ObjectStorageProvider              ← in BizFirst.Ai.InfraHub.Storage
        ├── IS3ObjectService               ← existing, extended (see Primary\design.md)
        │     └── AmazonS3Client (ForcePathStyle=true, ServiceURL=MinIO endpoint)
        └── IAiSessionContextAccessor      ← existing — provides TenantID
```

---

## Storage Architecture

### CID — Content Addressable ID

Files are identified by their content hash. Same bytes always produce the same CID.
Uploading the same file twice stores it once.

```
CID = SHA-256(fileBytes)  →  hex string
```

### Tenant Partitioning

Files are **always** written to a tenant-specific partition. Not configurable.

```
Storage key = tenant_{tenantId}/{cid}
```

TenantID is resolved internally from `ITenantContext` (ambient, set per-request).
Callers never pass TenantID — consistent with the platform-wide pattern.

### CID Format Option — `PrependTenantId`

Controlled by `FileStorageSettings.PrependTenantId` (default: `false`).

```
false (default): cid = hash              → key = tenant_42/bafybeig3x...
true (advanced): cid = {tenantId}_{hash} → key = tenant_42/42_bafybeig3x...
```

Advanced option prevents cross-tenant content inference from CID values alone.
With the default, an observer could infer two tenants hold the same file by comparing CIDs.

### Deduplication

Same file uploaded twice by the same tenant → same CID → existing object in
`tenant_{tenantId}/{cid}` detected → write skipped → existing CID returned.

### Logging Safety

Only `Cid`, `FileName`, and `MimeType` appear in storage service logs.
Raw bytes are never logged. The `StoreFileAsync` method logs the CID only after
the write completes.

---

## Storage Concerns

| Concern | Solution | Cost |
|---------|----------|------|
| Primary storage | MinIO on local disk | Own disk only |
| Backup | restic → Backblaze B2 | ~$0.006/GB/month |
| Point-in-time restore | restic snapshots | Included in backup |
| Archival (old files) | MinIO lifecycle → cold tier | Minimal |
| Hot standby | MinIO bucket replication | 2× storage cost |
| Compliance retention | Lifecycle expiry rules | Configurable per tenant |
| Business resiliency | Disk alerts, health checks, capacity planning, incident runbooks | Monitoring stack |

---

## Components

### `IObjectStorageProvider`

Defined in `BizFirst.Ai.Octopus.Abstraction`. The contract this project implements.

```csharp
public interface IObjectStorageProvider
{
    Task<string> StoreAsync(Stream stream, string? fileName, string? mimeType,
                            CancellationToken ct = default);
    Task<Stream> GetStreamAsync(string cid, CancellationToken ct = default);
    Task<bool>   ExistsAsync(string cid, CancellationToken ct = default);
}
```

- `StoreAsync` — computes CID, checks for duplicate, stores if new, returns CID
- `GetStreamAsync` — retrieves stream for the current tenant's copy of the CID
- TenantID resolved from `ITenantContextService` in both methods — never a parameter

### `S3ObjectStorageProvider`

Implementation in `BizFirst.Ai.Octopus.Infrastructure.Storage`.

Responsibilities:
- Compute SHA-256 CID from stream
- Apply `PrependTenantID` rule
- Construct storage key: `tenant_{tenantID}/{cid}`
- Check object existence before write (deduplication)
- Check disk capacity via MinIO metrics before every write
- Delegate to `IS3ObjectService` for actual S3 operations
- Log `cid`, `fileName`, `tenantID` — never raw bytes

### `FileStorageSettings`

```csharp
public class FileStorageSettings
{
    public string BucketName                { get; set; } = "bizfirst-files";
    public string Endpoint                  { get; set; } = string.Empty;  // blank = AWS; set for MinIO / R2 / B2
    public string AccessKey                 { get; set; } = string.Empty;
    public string SecretKey                 { get; set; } = string.Empty;
    public string Region                    { get; set; } = "us-east-1";
    public bool   ForcePathStyle            { get; set; } = true;   // required for MinIO
    public bool   PrependTenantID           { get; set; } = false;
    public double WriteStopThresholdPercent { get; set; } = 90.0;
}
```

---

## File Lifecycle (storage perspective)

```
STORE
  caller passes Stream + FileName + MimeType
       │
       ▼
  Read stream → byte[] → SHA-256(bytes) → hash
  PrependTenantID? → cid = "{tenantID}_{hash}" : cid = hash
  key = tenant_{tenantID}/{cid}
       │
       ▼
  Disk capacity guard (WriteStopThresholdPercent)
  ≥ threshold? → throw StorageCapacityException → HTTP 507
       │
       ▼
  Object exists at key?
    YES → return cid (skip write — dedup)
    NO  → IS3ObjectService.UploadAsync(key, bytes) → return cid

RETRIEVE
  caller passes cid
       │
       ▼
  key = tenant_{tenantID}/{cid}
  IS3ObjectService.DownloadStreamAsync(key) → Stream

ARCHIVAL (MinIO Lifecycle Policy — configured separately)
  Day 0:   Object stored (hot)
  Day 30:  Transitioned to cold storage class
  Day 365: Expired / deleted (unless compliance hold active)
```

---

## Project Structure

```
Modified projects (backward-compatible):
  BizFirst.Integration.S3.Domain\
    S3Credential.cs                       ← add ServiceURL?, ForcePathStyle for MinIO support
    Results\S3ObjectDownloadStreamResult.cs  ← new result record
    Results\S3ObjectExistsResult.cs          ← new result record
  BizFirst.Integration.S3.Services\
    Object\S3ObjectService.cs             ← update _CreateClient(), add DownloadStreamAsync(), ExistsAsync()
    Bucket\S3BucketService.cs             ← update _CreateClient()
    Folder\S3FolderService.cs             ← update _CreateClient()
    Interfaces\IS3ObjectService.cs        ← add DownloadStreamAsync, ExistsAsync + new request records

New projects:
  BizFirst.Ai.InfraHub.Storage.Domain\
    IObjectStorageProvider.cs             ← storage contract
    StorageCapacityException.cs           ← thrown when disk ≥ WriteStopThresholdPercent

  BizFirst.Ai.InfraHub.Storage\
    S3ObjectStorageProvider.cs            ← IObjectStorageProvider implementation
    FileStorageSettings.cs                ← config bound from "FileStorage" section
    FileStorageDependencyInjection.cs     ← AddObjectStorage() extension method

No changes to BizFirst.Ai.Octopus.Abstraction.
```

---

## Related Documents

- `Docker-WorkItem.md` — Docker team deliverables for MinIO + backup setup
- `Backup\` — restic + Backblaze B2 backup detail
- `Archival\` — MinIO lifecycle policy configuration
- `HotStandby\` — MinIO bucket replication setup
- `ComplianceRetention\` — per-tenant retention rules
