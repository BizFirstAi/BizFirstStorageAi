# Storage V1 — Plan and Status

**Project:** BizFirst Storage V1
**Started:** 2026-05-27
**Status:** WI-01 to WI-04 Implementation Complete — WI-05 to WI-09 pending Docker/DevOps team

---

## Delivery Overview

Storage V1 is delivered as a set of foundational projects. They are independent of
AI agents and nodes. Any part of the platform that needs to store or retrieve files
by CID will depend on these projects.

---

## Work Items

### WI-01 — Modify `BizFirst.Integration.S3.Domain`

**Status:** Complete (2026-05-27)
**Type:** Modify existing project
**Effort:** Small

**Changes:**
- Add `ServiceURL` (string?, default null) and `ForcePathStyle` (bool, default false)
  to `S3Credential` sealed record
- Both are backward-compatible additions — no existing callers break

**Files:**
- `S3Credential.cs`

**Acceptance:** Existing S3 node tests still pass. MinIO endpoint can be passed via credential.

---

### WI-02 — Modify `BizFirst.Integration.S3.Services`

**Status:** Complete (2026-05-27)
**Type:** Modify existing project
**Effort:** Small

**Changes:**
- Update `_CreateClient(S3Credential cred)` in all three services:
  - If `cred.ServiceURL` is set → use `ServiceURL` + `ForcePathStyle`
  - Else → use `RegionEndpoint.GetBySystemName(cred.Region)` (existing behaviour)
  - Applies to: `S3ObjectService`, `S3BucketService`, `S3FolderService`
- Add `DownloadStreamAsync(ObjectDownloadStreamRequest, S3Credential, CancellationToken)`
  to `IS3ObjectService` and `S3ObjectService`
  - Uses `AmazonS3Client.GetObjectAsync()` and returns `ResponseStream` directly
  - Add `ObjectDownloadStreamRequest` sealed record
  - Add `S3ObjectDownloadStreamResult` sealed record

**Files:**
- `S3ObjectService.cs`
- `S3BucketService.cs`
- `S3FolderService.cs`
- `Interfaces\IS3ObjectService.cs`
- `Interfaces\Requests\ObjectDownloadStreamRequest.cs` (new)
- `Domain (WI-01): S3ObjectDownloadStreamResult.cs` (new, in Domain)

**Acceptance:** `S3ObjectService.DownloadStreamAsync()` returns a live stream. Existing
`DownloadAsync()` unchanged.

---

### WI-03 — Create `BizFirst.Ai.InfraHub.Storage.Domain` (New Project)

**Status:** Complete (2026-05-27)
**Type:** New project
**Effort:** Small
**Path:** `BizFirstPayrollV3\src\mvc-server\InfraHub\BizFirst.Ai.InfraHub.Storage.Domain\`

**New project structure:**
```
BizFirst.Ai.InfraHub.Storage.Domain\
  IObjectStorageProvider.cs
  StoreOptions.cs
  StorageCapacityException.cs
```

**`StoreOptions`** — per-request overrides (null = use global default):
```csharp
public sealed record StoreOptions(
    string? CannedAcl    = null,
    string? StorageClass = null
);
```

**`IObjectStorageProvider`:**
```csharp
namespace BizFirst.Ai.InfraHub.Storage.Domain;

public interface IObjectStorageProvider
{
    Task<string> StoreAsync(Stream stream, string? fileName, string? mimeType,
                            StoreOptions? options = null,
                            CancellationToken ct  = default);
    Task<Stream> GetStreamAsync(string cid, CancellationToken ct = default);
    Task<bool>   ExistsAsync(string cid, CancellationToken ct = default);
}
```

**`StorageCapacityException`:**
```csharp
public class StorageCapacityException : Exception
{
    public StorageCapacityException(string message) : base(message) { }
}
```

**Note:** `ITenantContextService` is NOT needed. `S3ObjectStorageProvider` injects
`IAiSessionContextAccessor` directly and calls `.CurrentRequestSession.TenantID`.
Nothing is added to `BizFirst.Ai.Octopus.Abstraction`.

**Acceptance:** `IObjectStorageProvider` compiles. No dependency on Octopus projects.

---

### WI-04 — Create `BizFirst.Ai.InfraHub.Storage` (New Project)

**Status:** Complete (2026-05-27)
**Type:** New project
**Effort:** Medium
**Path:** `BizFirstPayrollV3\src\mvc-server\InfraHub\BizFirst.Ai.InfraHub.Storage\`

**New project structure:**
```
BizFirst.Ai.InfraHub.Storage\
  S3ObjectStorageProvider.cs
  FileStorageSettings.cs
  FileStorageDependencyInjection.cs
```

**References:**
- `BizFirst.Ai.InfraHub.Storage.Domain` (WI-03)
- `BizFirst.Integration.S3.Services` (WI-02)
- `BizFirst.Integration.S3.Domain` (WI-01)
- `BizFirst.Ai.AiSession.Domain` (for `IAiSessionContextAccessor`)
- `AWSSDK.S3` (already used in S3.Services)

**`S3ObjectStorageProvider` responsibilities:**
1. Read stream → buffer to byte[] → compute SHA-256 CID
2. Resolve TenantID via `IAiSessionContextAccessor.CurrentRequestSession.TenantID`
3. Apply `PrependTenantID` rule → build storage key `tenant_{id}/{cid}`
4. Call `ExistsAsync()` → skip write if already stored (dedup)
5. Call `IS3ObjectService.UploadAsync()` with byte[]
6. On retrieve: call `IS3ObjectService.DownloadStreamAsync()` (WI-02)
7. Guard disk capacity at `WriteStopThresholdPercent` via MinIO metrics endpoint
8. Throw `StorageCapacityException` if threshold exceeded → callers return HTTP 507

**`FileStorageSettings`:**
- BucketName, Endpoint, AccessKey, SecretKey, Region, ForcePathStyle
- CannedAcl (default: `"NoACL"`) — global default, overridable per-request via `StoreOptions`
- StorageClass (default: `"STANDARD"`) — global default, overridable per-request via `StoreOptions`
- PrependTenantID (default: false)
- WriteStopThresholdPercent (default: 90.0)

**`FileStorageDependencyInjection`:**
- `AddObjectStorage(this IServiceCollection, IConfiguration)` extension method
- Binds `FileStorageSettings` from `"FileStorage"` config section
- Calls `services.AddS3Services()` (existing)
- Registers `IObjectStorageProvider → S3ObjectStorageProvider` (scoped)

**Acceptance:**
- Upload a file → returns CID
- Upload same file again → returns same CID, no second write (dedup)
- Retrieve by CID → returns stream
- Works against MinIO (Docker) and AWS S3 (cloud)
- Throws `StorageCapacityException` when disk ≥ 90%

---

### WI-05 — Docker: MinIO Container Setup

**Status:** Not Started
**Type:** Docker team deliverable
**Owner:** Docker Team
**Reference:** `Docker-WorkItem.md`

**Deliverables:**
- MinIO container in `docker-compose.yml`
- MinIO init container (creates `bizfirst-files` bucket)
- Dedicated app user (non-root credentials)
- Health check on `/minio/health/ready`
- App container env vars: `FileStorage__Endpoint`, `FileStorage__AccessKey`, etc.
- `.env` file entries for all MinIO secrets

**Acceptance:** `curl http://localhost:9000/minio/health/ready` returns 200.
App container can upload and retrieve a test file.

---

### WI-06 — Docker: Backup Container Setup

**Status:** Not Started
**Type:** Docker team deliverable
**Owner:** Docker Team
**Reference:** `Docker-WorkItem.md`, `Design\Backup\design.md`

**Deliverables:**
- restic backup container in `docker-compose.yml`
- Backblaze B2 bucket created and credentials configured
- restic repository initialised
- Host cron job (or cron sidecar) running daily at 02:00
- Verify `restic check` runs after backup

**Acceptance:** Daily backup runs. `restic snapshots` shows at least one snapshot.
`restic restore` recovers a test file.

---

### WI-07 — MinIO Bucket Quota (90% Write Stop)

**Status:** Not Started
**Type:** Operations / Docker team
**Reference:** `Design\Resiliency\StopWritesAt90Percent.md`

**Deliverables:**
- Calculate bucket quota bytes = disk_total × 0.90
- Apply via `mc admin bucket quota myminio/bizfirst-files --hard {bytes}`
- Document the quota value and disk size it was based on

**Acceptance:** Attempting to write beyond quota returns `XMinioStorageFull`.

---

### WI-08 — MinIO Lifecycle Policy (Archival)

**Status:** Not Started
**Type:** Operations / Docker team
**Reference:** `Design\Archival\design.md`

**Deliverables:**
- Apply lifecycle JSON policy via `mc ilm import`
- Verify `mc ilm ls` shows active rules
- Configure cold tier target if cold storage is available

**Acceptance:** Objects older than 30 days are transitioned. Objects at 365 days are expired.

---

### WI-09 — Resiliency Monitoring Setup

**Status:** Not Started
**Type:** Operations / DevOps
**Reference:** `Design\Resiliency\design.md`

**Deliverables:**
- Prometheus scrape config for MinIO metrics endpoint
- Alert rules at 70% (warning), 85% (critical), 95% (emergency)
- OR: cron-based disk check script if no Prometheus stack

**Acceptance:** Alert fires when disk exceeds threshold. Ops team is notified.

---

### WI-10 — Hot Standby (Optional — Phase 2)

**Status:** Deferred
**Type:** Docker team
**Reference:** `Design\HotStandby\design.md`
**Note:** Deliver after primary + backup are stable in production.

---

### WI-11 — Compliance Retention (Optional — On Demand)

**Status:** Deferred
**Type:** Operations — per-tenant setup
**Reference:** `Design\ComplianceRetention\design.md`
**Note:** Configure when a specific tenant has legal retention requirements.

---

## Delivery Order

```
Phase 1 — Core storage (unblocks all consumers)
  WI-01  S3.Domain: S3Credential MinIO fields
  WI-02  S3.Services: _CreateClient + DownloadStreamAsync
  WI-03  Abstraction: IObjectStorageProvider + ITenantContextService
  WI-04  Infrastructure.Storage: S3ObjectStorageProvider (new project)

Phase 2 — Infrastructure (parallel with Phase 1 coding)
  WI-05  Docker: MinIO container
  WI-06  Docker: Backup container
  WI-07  MinIO bucket quota
  WI-08  MinIO lifecycle policy
  WI-09  Resiliency monitoring

Phase 3 — Deferred
  WI-10  Hot standby
  WI-11  Compliance retention
```

---

## Project Dependencies

```
BizFirst.Integration.S3.Domain                 (WI-01)
  └── BizFirst.Integration.S3.Services         (WI-02, depends on WI-01)

BizFirst.Ai.InfraHub.Storage.Domain      (WI-03, independent)
  IObjectStorageProvider, StorageCapacityException

BizFirst.Ai.InfraHub.Storage             (WI-04)
  depends on: WI-01, WI-02, WI-03
  depends on: BizFirst.Ai.AiSession.Domain (IAiSessionContextAccessor — existing)

Consumer projects (proposed-changes.md)
  depend on: WI-03 (IObjectStorageProvider)
```

---

## Design Documents Index

| Document | Status |
|----------|--------|
| `Design\design.md` | Complete |
| `Design\Primary\design.md` | Complete — all DesignReview corrections applied |
| `Design\Backup\design.md` | Complete |
| `Design\PointInTimeRestore\design.md` | Complete |
| `Design\Archival\design.md` | Complete |
| `Design\HotStandby\design.md` | Complete |
| `Design\ComplianceRetention\design.md` | Complete |
| `Design\Resiliency\design.md` | Complete |
| `Design\Resiliency\StopWritesAt90Percent.md` | Complete |
| `DesignReview.md` | Complete |
| `Docker-WorkItem.md` | Complete — ready to send to Docker team |

---

## Open Questions Before Coding

| # | Question | Owner |
|---|----------|-------|
| 1 | What is the actual disk size of the production server? Needed for WI-07 bucket quota. | Docker team |
| 2 | Is Prometheus available in the stack, or use cron script for WI-09? | DevOps |
| 3 | Is `ITenantContextService` from `SqlServerAtlasStorage` plugin the right source of TenantID, or is there another mechanism? | Architecture |
| 4 | Should `S3ObjectStorageProvider` be in the V21 solution or in PayrollV3? | Architecture |
| 5 | Backblaze B2 account — who creates the bucket and keys for WI-06? | DevOps |
