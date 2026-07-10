# Storage V1 — Design Review

Review of all design documents against the actual codebase.
Date: 2026-05-27

---

## Finding 1 — CRITICAL: `IFileStorageProvider` Already Exists With Different Purpose

**Status: Design must be corrected**

The design uses `IFileStorageProvider` as the name for the new CID-based object storage
interface. This name is already taken.

**Existing interface:**
```
BizFirst.Ai.Octopus.Abstraction\Files\IFileStorageProvider.cs
Namespace: BizFirst.Ai.Octopus.Abstraction.Files
```

The existing `IFileStorageProvider` is a **local filesystem provider** for conversation
files, user avatars, knowledge base files, speech files, etc. It has 20+ methods with
no concept of CID, tenant partitioning, or object storage. It is implemented by
`LocalFileStorageProvider` in `BizFirst.Ai.Octopus.Core`.

**Correction:** Rename the new interface to `IObjectStorageProvider`.

```csharp
// Correct name — no collision with existing interface
public interface IObjectStorageProvider
{
    Task<string> StoreAsync(Stream stream, string? fileName, string? mimeType,
                            CancellationToken ct = default);
    Task<Stream> GetStreamAsync(string cid, CancellationToken ct = default);
    Task<bool>   ExistsAsync(string cid, CancellationToken ct = default);
}
```

**Files to update:**
- `Design\Primary\design.md`
- `Design\design.md`
- `Design\Resiliency\StopWritesAt90Percent.md`
- `proposed-changes.md` (consumer design)

---

## Finding 2 — CRITICAL: `S3ObjectService` Does Not Support MinIO Endpoint

**Status: Existing code must be modified**

The design states "MinIO requires only two config changes." This is correct in principle
but the existing `S3ObjectService._CreateClient(S3Credential cred)` does NOT have
`ServiceURL` or `ForcePathStyle` — it only uses `RegionEndpoint.GetBySystemName()`.

**Existing client creation (exact code):**
```csharp
var config = new AmazonS3Config
{
    RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(cred.Region),
    Timeout        = TimeSpan.FromSeconds(60),
    MaxErrorRetry  = 3
};
```

No `ServiceURL`. No `ForcePathStyle`. Pointing this at MinIO will fail.

**Correction:** Add optional `ServiceURL` and `ForcePathStyle` to `S3Credential`
in the Domain project. Both are backward-compatible additions (null/false defaults
preserve existing AWS S3 behaviour).

```csharp
// BizFirst.Integration.S3.Domain — S3Credential.cs (modify)
public sealed record S3Credential(
    string  AccessKeyID,
    string  SecretKey,
    string? SessionToken,
    string  Region,
    string? ServiceURL    = null,   // null = standard AWS; "http://minio:9000" for MinIO
    bool    ForcePathStyle = false  // true required for MinIO
);
```

```csharp
// BizFirst.Integration.S3.Services — _CreateClient() (modify in all 3 services)
var config = new AmazonS3Config
{
    Timeout       = TimeSpan.FromSeconds(60),
    MaxErrorRetry = 3
};

if (!string.IsNullOrWhiteSpace(cred.ServiceURL))
{
    config.ServiceURL    = cred.ServiceURL;
    config.ForcePathStyle = cred.ForcePathStyle;
}
else
{
    config.RegionEndpoint = Amazon.RegionEndpoint.GetBySystemName(cred.Region);
}
```

**Files to modify:**
- `BizFirst.Integration.S3.Domain\Common\S3Credential.cs`
- `BizFirst.Integration.S3.Services\Object\S3ObjectService.cs`
- `BizFirst.Integration.S3.Services\Bucket\S3BucketService.cs`
- `BizFirst.Integration.S3.Services\Folder\S3FolderService.cs`

---

## Finding 3 — CRITICAL: `IS3ObjectService.DownloadAsync` Writes to File Path, Not Stream

**Status: Interface must be extended**

`S3ObjectDownloadResult` has a `LocalFilePath` (string?) field — the download writes
to disk. `GetStreamAsync()` in `IObjectStorageProvider` needs to return a `Stream`
without writing to disk first.

**Correction:** Add `DownloadStreamAsync` to `IS3ObjectService`.

```csharp
// BizFirst.Integration.S3.Services — IS3ObjectService.cs (add method)
Task<S3ObjectDownloadStreamResult> DownloadStreamAsync(
    ObjectDownloadStreamRequest req,
    S3Credential                cred,
    CancellationToken           ct);
```

```csharp
// New request record
public sealed record ObjectDownloadStreamRequest(
    string  BucketName,
    string  Region,
    string  ObjectKey,
    string? VersionId = null
);

// New result record
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
    public static S3ObjectDownloadStreamResult Ok(Stream stream, long size, string? eTag) => ...;
    public static S3ObjectDownloadStreamResult Fail(string errorCode, string message) => ...;
}
```

`S3ObjectService.DownloadStreamAsync()` uses `GetObjectAsync()` from AWSSDK.S3
and returns `response.ResponseStream` directly — no temp file.

---

## Finding 4 — CRITICAL: `ITenantContext` Does Not Exist

**Status: Design must be corrected**

The design references `ITenantContext` as if it is a standard platform interface.
It does not exist in `BizFirst.Ai.Octopus.Abstraction`.

**What exists:**
```
ITenantContextService — in BizFirst.Ai.Octopus.Plugin.SqlServerAtlasStorage.Services
Method: int GetCurrentTenantId()
```

This is in a plugin project, not in Abstraction. It is not appropriate to reference
a plugin from Infrastructure.Storage.

**Correction:** Create `ITenantContextService` in `BizFirst.Ai.Octopus.Abstraction`
as a platform-level interface (move the contract, not the implementation).

```csharp
// BizFirst.Ai.Octopus.Abstraction\Infrastructure\ITenantContextService.cs (new)
namespace BizFirst.Ai.Octopus.Abstraction.Infrastructure;

public interface ITenantContextService
{
    int GetCurrentTenantID();
}
```

`S3ObjectStorageProvider` injects `ITenantContextService` (Abstraction version).
The existing `TenantContextService` in the plugin implements both the existing and
new interface (or is updated to implement only the Abstraction one).

**Note:** `GetCurrentTenantId()` returns `int` — the storage key uses `int` TenantID:
```
key = tenant_{tenantId}/{cid}    e.g.  tenant_42/bafybeig3x...
```

---

## Finding 5 — `ObjectUploadRequest.FileContent` Is `byte[]` Not `Stream`

**Status: Implementation detail — handle in S3ObjectStorageProvider**

`ObjectUploadRequest` has `FileContent (byte[])` not a `Stream`. When `StoreAsync(Stream)`
is called, the provider must buffer the stream to a byte array before calling
`IS3ObjectService.UploadAsync()`. This is also where the SHA-256 CID is computed.

```csharp
// In S3ObjectStorageProvider.StoreAsync()
using var ms    = new MemoryStream();
await stream.CopyToAsync(ms, ct);
var bytes       = ms.ToArray();
var cid         = ComputeSha256Hex(bytes);
// ... then build ObjectUploadRequest with FileContent = bytes
```

No design change needed — implementation detail to handle in code.

---

## Finding 6 — `ObjectUploadRequest` Requires `Region` Field

**Status: Implementation detail**

Every request record in `BizFirst.Integration.S3.Services` includes a `Region` field.
`FileStorageSettings.Region` provides this value. No design change needed.

---

## Finding 7 — `FileStorageEnum` Already Has `AmazonS3Storage` Constant

**Status: Informational — opportunity to align**

`FileStorageEnum` in `BizFirst.Ai.Octopus.Abstraction` already has:
- `LocalFileStorage`
- `AmazonS3Storage`
- `AzureBlobStorage`
- `TencentCosStorage`

This enum can be used to control which `IObjectStorageProvider` implementation is
registered at startup. No design change needed but worth aligning in DI registration.

---

## Corrected Project Structure

```
BizFirst.Integration.S3.Domain              MODIFY — add ServiceURL, ForcePathStyle to S3Credential
BizFirst.Integration.S3.Services            MODIFY — update _CreateClient() × 3, add DownloadStreamAsync

BizFirst.Ai.Octopus.Abstraction             MODIFY — add:
  Infrastructure\ITenantContextService.cs     ← new platform interface
  Storage\IObjectStorageProvider.cs           ← new (renamed from IFileStorageProvider)

BizFirst.Ai.Octopus.Infrastructure.Storage  NEW — new project:
  S3ObjectStorageProvider.cs
  FileStorageSettings.cs
  FileStorageDependencyInjection.cs
```

---

## Corrected `IObjectStorageProvider`

```csharp
namespace BizFirst.Ai.Octopus.Abstraction.Storage;

public interface IObjectStorageProvider
{
    /// <summary>Stores a file. Returns CID. Deduplicates within tenant.</summary>
    Task<string> StoreAsync(Stream    stream,
                            string?   fileName,
                            string?   mimeType,
                            CancellationToken ct = default);

    /// <summary>Retrieves a file stream by CID for the current tenant.</summary>
    Task<Stream> GetStreamAsync(string cid, CancellationToken ct = default);

    /// <summary>Checks if a CID exists for the current tenant.</summary>
    Task<bool> ExistsAsync(string cid, CancellationToken ct = default);
}
```

---

## Corrected `FileStorageSettings`

```csharp
public class FileStorageSettings
{
    public string BucketName               { get; set; } = "bizfirst-files";
    public string Endpoint                 { get; set; } = string.Empty;  // blank = AWS S3
    public string AccessKey                { get; set; } = string.Empty;
    public string SecretKey                { get; set; } = string.Empty;
    public string Region                   { get; set; } = "us-east-1";
    public bool   ForcePathStyle           { get; set; } = true;
    public bool   PrependTenantID          { get; set; } = false;
    public double WriteStopThresholdPercent { get; set; } = 90.0;
}
```

Note: `Id` → `ID` per platform naming convention.

---

## Documents Updated After Review

| Document | Correction | Status |
|----------|-----------|--------|
| `Design\design.md` | `IFileStorageProvider` → `IObjectStorageProvider`, updated project structure | Done |
| `Design\Primary\design.md` | All 5 findings applied — full rewrite with correct types, methods, naming | Done |
| `Design\Resiliency\StopWritesAt90Percent.md` | `S3FileStorageProvider` → `S3ObjectStorageProvider`, `StoreFileAsync` → `StoreAsync` | Done |
| `proposed-changes.md` | Consumer references — pending (separate task) | Pending |
