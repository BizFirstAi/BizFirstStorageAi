# Storage V1 — Resource File

All code files and documentation references for the Storage V1 implementation.

---

## Solution

| File | Path |
|------|------|
| `BizFirst.Ai.InfraHub.sln` | `BizFirstPayrollV3\src\mvc-server\InfraHub\BizFirst.Ai.InfraHub.sln` |

---

## WI-01 — BizFirst.Integration.S3.Domain *(modified)*

**Path:** `BizFirstPayrollV3\src\mvc-server\AI\ExecutionNodes\Productivity\S3\BizFirst.Integration.S3.Domain\`

| File | Purpose |
|------|---------|
| `BizFirst.Integration.S3.Domain.csproj` | Project file |
| `Using.cs` | Global usings |
| `Common\S3Credential.cs` | ★ Added `ServiceURL?` and `ForcePathStyle` — enables MinIO/S3-compatible endpoints |
| `Results\S3ObjectDownloadStreamResult.cs` | ★ New — result record for streaming download |
| `Results\S3ObjectExistsResult.cs` | ★ New — result record for object existence check |
| `Results\S3ObjectUploadResult.cs` | Pre-existing |
| `Results\S3ObjectDownloadResult.cs` | Pre-existing |
| `Results\S3ObjectCopyResult.cs` | Pre-existing |
| `Results\S3ObjectDeleteResult.cs` | Pre-existing |
| `Results\S3ObjectGetManyResult.cs` | Pre-existing |
| `Results\S3BucketCreateResult.cs` | Pre-existing |
| `Results\S3BucketDeleteResult.cs` | Pre-existing |
| `Results\S3BucketListAllResult.cs` | Pre-existing |
| `Results\S3BucketSearchResult.cs` | Pre-existing |
| `Results\S3FolderCreateResult.cs` | Pre-existing |
| `Results\S3FolderDeleteResult.cs` | Pre-existing |
| `Results\S3FolderGetManyResult.cs` | Pre-existing |
| `Models\S3ObjectSummary.cs` | Pre-existing |
| `Models\S3FolderEntry.cs` | Pre-existing |
| `DevelopmentHistoryLog.md` | Change history |

---

## WI-02 — BizFirst.Integration.S3.Services *(modified)*

**Path:** `BizFirstPayrollV3\src\mvc-server\AI\ExecutionNodes\Productivity\S3\BizFirst.Integration.S3.Services\`

| File | Purpose |
|------|---------|
| `BizFirst.Integration.S3.Services.csproj` | Project file |
| `Using.cs` | ★ Added `global using System.Net` |
| `Common\S3ClientFactory.cs` | ★ New — extracted `AmazonS3Client` construction (ServiceURL/RegionEndpoint/SessionToken branches); removes duplication from all 3 services |
| `Common\S3ErrorCodes.cs` | Pre-existing error code constants |
| `Interfaces\IS3ObjectService.cs` | ★ Added `DownloadStreamAsync` + `ExistsAsync` methods; added `ObjectDownloadStreamRequest` + `ObjectExistsRequest` records |
| `Interfaces\IS3BucketService.cs` | Pre-existing |
| `Interfaces\IS3FolderService.cs` | Pre-existing |
| `Object\S3ObjectService.cs` | ★ Updated: `S3ClientFactory.Create` replaces inline `_CreateClient`; added `DownloadStreamAsync`; added `ExistsAsync`; fixed `GetObjectResponse` disposal |
| `Bucket\S3BucketService.cs` | ★ Updated: `S3ClientFactory.Create` replaces inline `_CreateClient` |
| `Folder\S3FolderService.cs` | ★ Updated: `S3ClientFactory.Create` replaces inline `_CreateClient` |
| `DependencyInjection\S3ServicesExtensions.cs` | Pre-existing DI registration (`AddS3Services`) |
| `DevelopmentHistoryLog.md` | Change history |

---

## WI-03 — BizFirst.Ai.InfraHub.Storage.Domain *(new project)*

**Path:** `BizFirstPayrollV3\src\mvc-server\InfraHub\Storage\BizFirst.Ai.InfraHub.Storage.Domain\`

| File | Purpose |
|------|---------|
| `BizFirst.Ai.InfraHub.Storage.Domain.csproj` | Project file — no external dependencies |
| `IObjectStorageProvider.cs` | Storage contract: `StoreAsync` / `GetStreamAsync` / `ExistsAsync` |
| `Options\StoreOptions.cs` | Per-request overrides: `CannedAcl?`, `StorageClass?` |
| `Exceptions\StorageCapacityException.cs` | Thrown when disk ≥ threshold; callers return HTTP 507 |
| `DevelopmentHistoryLog.md` | Change history |

---

## WI-04 — BizFirst.Ai.InfraHub.Storage.S3.Services *(new project)*

**Path:** `BizFirstPayrollV3\src\mvc-server\InfraHub\Storage\S3\BizFirst.Ai.InfraHub.Storage.S3.Services\`

| File | Purpose |
|------|---------|
| `BizFirst.Ai.InfraHub.Storage.S3.Services.csproj` | Project file |
| `FileStorageDependencyInjection.cs` | `AddObjectStorage(IServiceCollection, IConfiguration)` — binds settings, registers all services |
| `Settings\FileStorageSettings.cs` | Bound from `"FileStorage"` config section: BucketName, Endpoint, AccessKey, SecretKey, Region, ForcePathStyle, CannedAcl, StorageClass, PrependTenantID, WriteStopThresholdPercent |
| `Interfaces\ICidProvider.cs` | Contract: `Compute(byte[])` → CID string |
| `Interfaces\IStorageCapacityGuard.cs` | Contract: `EnforceAsync(ct)` — throws `StorageCapacityException` if over threshold |
| `Cid\Sha256CidProvider.cs` | Implements `ICidProvider` — SHA-256(bytes) → lowercase hex |
| `CapacityGuard\MinioCapacityGuard.cs` | Implements `IStorageCapacityGuard` — reads MinIO Prometheus metrics endpoint |
| `Providers\S3ObjectStorageProvider.cs` | Implements `IObjectStorageProvider` (thin) — delegates to `ICidProvider`, `IStorageCapacityGuard`, `IS3ObjectService` |
| `DevelopmentHistoryLog.md` | Change history |

---

## Project Dependency Graph

```
BizFirst.Integration.S3.Domain                          (WI-01)
  └── BizFirst.Integration.S3.Services                  (WI-02)
        depends on: WI-01

BizFirst.Ai.InfraHub.Storage.Domain                     (WI-03)
  — no dependencies —

BizFirst.Ai.InfraHub.Storage.S3.Services                (WI-04)
  depends on: WI-01  (S3Credential, request/result records)
  depends on: WI-02  (IS3ObjectService, S3ClientFactory)
  depends on: WI-03  (IObjectStorageProvider, StoreOptions, StorageCapacityException)
  depends on: BizFirst.Ai.AiSession.Domain  (IAiSessionContextAccessor → TenantID)

Consumer projects
  depend on: WI-03  (IObjectStorageProvider only)
  call: services.AddObjectStorage(config)  from WI-04
```

---

## DI Registrations (AddObjectStorage)

| Interface | Implementation | Lifetime |
|-----------|---------------|---------|
| `ICidProvider` | `Sha256CidProvider` | Singleton |
| `IStorageCapacityGuard` | `MinioCapacityGuard` | Scoped |
| `IObjectStorageProvider` | `S3ObjectStorageProvider` | Scoped |

Plus: `IS3ObjectService`, `IS3BucketService`, `IS3FolderService` registered via `AddS3Services()`.

---

## Configuration (appsettings / env vars)

| Key | Env Var | Default | Notes |
|-----|---------|---------|-------|
| `FileStorage:BucketName` | `FileStorage__BucketName` | `bizfirst-files` | |
| `FileStorage:Endpoint` | `FileStorage__Endpoint` | *(blank)* | Blank = AWS S3; set to `http://minio:9000` for MinIO |
| `FileStorage:AccessKey` | `FileStorage__AccessKey` | *(required)* | MinIO/AWS access key |
| `FileStorage:SecretKey` | `FileStorage__SecretKey` | *(required)* | MinIO/AWS secret key |
| `FileStorage:Region` | `FileStorage__Region` | `us-east-1` | |
| `FileStorage:ForcePathStyle` | `FileStorage__ForcePathStyle` | `true` | Required for MinIO |
| `FileStorage:CannedAcl` | `FileStorage__CannedAcl` | `NoACL` | Per-request override via `StoreOptions.CannedAcl` |
| `FileStorage:StorageClass` | `FileStorage__StorageClass` | `STANDARD` | Per-request override via `StoreOptions.StorageClass` |
| `FileStorage:PrependTenantID` | `FileStorage__PrependTenantID` | `false` | Prefix CID with TenantID |
| `FileStorage:WriteStopThresholdPercent` | `FileStorage__WriteStopThresholdPercent` | `90.0` | Set 0 to disable guard |

---

## Documentation Files

| File | Purpose |
|------|---------|
| `PlanAndStatus.md` | Work items WI-01 to WI-11 with status |
| `qna1.md` | Design gaps, questions, and answers from pre-coding review |
| `DesignReview.md` | Full design review findings and corrections |
| `Docker-WorkItem.md` | Docker team deliverables: MinIO container, backup, env vars |
| `Design\design.md` | Top-level design overview |
| `Design\Primary\design.md` | Primary storage design (S3ObjectStorageProvider architecture) |
| `Design\Backup\design.md` | Backup strategy using restic + Backblaze B2 |
| `Design\PointInTimeRestore\design.md` | Point-in-time restore design |
| `Design\Archival\design.md` | Lifecycle archival policy |
| `Design\HotStandby\design.md` | Hot standby (Phase 2, deferred) |
| `Design\ComplianceRetention\design.md` | Compliance retention (on-demand) |
| `Design\Resiliency\design.md` | Resiliency and monitoring design |
| `Design\Resiliency\StopWritesAt90Percent.md` | Write-stop threshold design |

---

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| CID algorithm | SHA-256 → lowercase hex | Content-addressable, deterministic dedup |
| Storage key format | `tenant_{tenantID}/{cid}` | Tenant isolation at key level |
| TenantID source | `IAiSessionContextAccessor.CurrentRequestSession.TenantID` (int) | Foundation project — no Octopus coupling |
| Default CannedAcl | `NoACL` | Compatible with MinIO, AWS BucketOwnerEnforced, R2, B2 |
| Capacity guard | Prometheus metrics `{Endpoint}/minio/v2/metrics/cluster` | App-level guard before bucket quota kicks in |
| Stream handling | Buffer to `MemoryStream` before returning | Safe client disposal; V2 can optimize |
| SRP split | `ICidProvider` + `IStorageCapacityGuard` + `S3ObjectStorageProvider` | Each class has one reason to change |
| Client construction | `S3ClientFactory.Create(cred)` shared across all 3 services | Single point for ServiceURL/RegionEndpoint/SessionToken logic |
