# Storage V1 — Pre-Coding Q&A

Date: 2026-05-27
Source: Codebase tally against design documents

---

## Gaps Found (Design Must Be Corrected)

### Gap 1 — `ExistsAsync` Missing From `IS3ObjectService`

The design calls `_objects.ExistsAsync(...)` inside `S3ObjectStorageProvider` but
`IS3ObjectService` has no `ExistsAsync` method. WI-02 did not list this.

**Must add to WI-02:**
- `ObjectExistsRequest` sealed record (in `IS3ObjectService.cs`)
- `S3ObjectExistsResult` sealed record (in `S3.Domain\Results\`)
- `ExistsAsync` on `IS3ObjectService` interface
- `ExistsAsync` on `S3ObjectService` — implemented via `GetObjectMetadataAsync`,
  returns `false` on `NoSuchKey` exception

---

### Gap 2 — `ITenantContextService` Does Not Exist Anywhere

Design Review Finding 4 stated it was in the SqlServerAtlasStorage plugin.
The full codebase scan found no such interface anywhere.

**What actually exists:**
- `TenantContextMiddleware` in `BizFirst.Ai.AiConversation.Api.Base.Middleware`
- Reads TenantId from JWT claims
- Stores it in `HttpContext.Items["TenantId"]`

**Impact:** The concrete implementation of `ITenantContextService` (to be created in
Abstraction) must use `IHttpContextAccessor` to read from `HttpContext.Items["TenantId"]`.
It cannot wrap any existing plugin class.

---

### Gap 3 — `_CreateClient` Session Token Branch Must Be Preserved

The updated `_CreateClient` in the design drops the session token handling.
The existing code has a second branch:

```csharp
if (!string.IsNullOrEmpty(cred.SessionToken))
{
    var sessionCredentials = new SessionAWSCredentials(
        cred.AccessKeyId, cred.SecretKey, cred.SessionToken);
    return new AmazonS3Client(sessionCredentials, config);
}
return new AmazonS3Client(basicCredentials, config);
```

**Correction:** Only the `config` block changes. The credential branching logic stays.

---

### Gap 4 — `ObjectUploadRequest` Constructor Has 11 Required Fields

The design showed 5 fields and included a non-existent `FileName` field.
The actual sealed record requires:

```csharp
public sealed record ObjectUploadRequest(
    string BucketName,
    string Region,
    string ObjectKey,
    byte[] FileContent,
    string ContentType,
    string StorageClass,          // required — no default
    string ServerSideEncryption,  // required — no default
    string? KmsKeyId,
    string CannedAcl,             // required — no default
    Dictionary<string, string>? Metadata,
    Dictionary<string, string>? Tagging);
```

`FileName` does not exist on this record.

**Planned defaults for `S3ObjectStorageProvider.StoreAsync`:**
- `StorageClass = "STANDARD"`
- `ServerSideEncryption = ""`
- `KmsKeyId = null`
- `Metadata = null`
- `Tagging = null`
- `CannedAcl = ?` ← **see Q3 below**

---

### Gap 5 — `AccessKeyId` vs `AccessKeyID`

The existing `S3Credential` record field is `AccessKeyId` (lowercase `d`).
The design documents show `AccessKeyID` throughout.

All code written against `S3Credential` must use the actual field name.
This is a naming decision — see Q1 below.

---

## Questions

### Q1 — Rename `S3Credential.AccessKeyId` → `AccessKeyID`?

WI-01 is already modifying `S3Credential` to add `ServiceURL` and `ForcePathStyle`.
The existing field `AccessKeyId` violates the platform `ID` uppercase convention.

**Option A — Rename in WI-01:**
Change `AccessKeyId` → `AccessKeyID` in the same commit.
Requires updating every caller in S3 node callers (BizFirstPayrollV3 S3 nodes).
Clean going forward.

**Option B — Leave as-is:**
Keep `AccessKeyId` unchanged. Only apply the `ID` convention to the two new fields.
No impact on existing callers. Inconsistency remains in the record.

**Recommendation: Option A — rename now.**
WI-01 is already the only planned touch to `S3Credential`. If this is not fixed here, it
never will be — the inconsistency compounds every time a new caller is written. The S3
node callers are a known, bounded set; a find-replace sweep across them is low-risk and
takes minutes. The convention exists for a reason: `ID` is unambiguous in code review
and API surfaces. Pay the small cost once.

**Answer:** _______________

---

### Q2 — What is the correct source of TenantID?

Initial assumption was `TenantContextMiddleware` / `HttpContext.Items`.
Codebase scan found the actual mechanism: `IAiSessionContextAccessor` in
`BizFirst.Ai.AiSession.Domain` (project: `BizFirstPayrollV3\AI\AiSession`).

```
IAiSessionContextAccessor.CurrentRequestSession.TenantID
  → RequestAiSession.TenantID   (computed: int)
  → User.App.Account.TenantID
  → AccountAiSession.TenantID
  → TenantSessionData.TenantID  (required int — source of truth)
```

Registered as `Singleton` in `AddAiSessionServices()`. Uses `AsyncLocal<T>` internally
for per-async-context isolation — safe to use from a scoped service.

**Recommendation: inject `IAiSessionContextAccessor`, read `CurrentRequestSession.TenantID`.**

```csharp
// Concrete implementation of ITenantContextService (in Infrastructure.Storage project)
public class AiSessionTenantContextService : ITenantContextService
{
    private readonly IAiSessionContextAccessor _session;

    public AiSessionTenantContextService(IAiSessionContextAccessor session)
        => _session = session;

    public int GetCurrentTenantID() => _session.CurrentRequestSession.TenantID;
}
```

No `IHttpContextAccessor` needed. `TenantID` is `int` — confirmed by `TenantSessionData.TenantID`.
`ITenantContextService` interface stays in the foundation abstraction (not in Octopus).

**Answer:** IAiSessionContextAccessor / int confirmed

---

### Q3 — What `CannedAcl` value should `S3ObjectStorageProvider` use?

`ObjectUploadRequest.CannedAcl` is a required non-null string. It is parsed via
`Enum.Parse(typeof(S3CannedACL), req.CannedAcl, ignoreCase: true)`.

MinIO does not enforce S3 ACLs by default. Valid options:
- `"NoACL"` — maps to `S3CannedACL.NoACL`, no ACL header sent
- `"private"` — maps to `S3CannedACL.Private`, standard private object

**Recommendation: `"NoACL"` as global default, overridable per-request via `StoreOptions`.**
`"NoACL"` works on MinIO, modern AWS S3 (BucketOwnerEnforced), R2, and B2.
`"private"` breaks on new AWS S3 buckets where ACLs are disabled.
Access control is enforced by tenant-partitioned storage keys and credentials — not ACLs.
Both `CannedAcl` and `StorageClass` are now fields on `FileStorageSettings` (global default)
and can be overridden per-call via `StoreOptions`. Per-tenant DB config deferred to V2.

**Answer: CONFIRMED — `"NoACL"` default. `StoreOptions` added for per-request override.
Per-tenant via DB deferred to V2.**

---

### Q4 — Confirm TenantID Type (int or string)?

`GetCurrentTenantID()` in the design returns `int`, based on the assumption that
TenantID is numeric. Confirm this is correct before implementing.

**Recommendation: `int`.**
TenantID is a database-backed identity key. All `INT` foreign keys in the platform follow
the DB standards (see feedback memory). SQL Server `INT` maps to C# `int`. The storage
key `tenant_42/cid` uses the numeric value directly — using `int` is both correct and
compact. If TenantID ever becomes a GUID-based key this would be a single-interface change.

**Answer: CONFIRMED — `int`. `TenantSessionData.TenantID` is `required int`.**

---

### Q5 — Where does the Storage project live, and what is its name?

**Architecture correction (user-confirmed):**
This is a **foundation project** — it does not belong to Octopus.

**Answer: Two new projects in `PayrollV3\AI\Infrastructure\Storage\`:**

```
BizFirst.Ai.InfraHub.Storage.Domain    ← IObjectStorageProvider, StorageCapacityException
BizFirst.Ai.InfraHub.Storage           ← S3ObjectStorageProvider, FileStorageSettings, DI
```

Mirrors the pattern already established by `BizFirst.Integration.S3.Domain` +
`BizFirst.Integration.S3.Services`. Domain holds the contract; Services holds
the implementation. `IObjectStorageProvider` lives in the Domain project — NOT in
`BizFirst.Ai.Octopus.Abstraction`.

---

### Q6 — `ITenantContextService` needed?

**Answer: NO. Inject `IAiSessionContextAccessor` directly.**

`IAiSessionContextAccessor.CurrentRequestSession.TenantID` returns `int` directly.
No wrapper interface required. `S3ObjectStorageProvider` injects
`IAiSessionContextAccessor` from `BizFirst.Ai.AiSession.Domain`.

```csharp
// In S3ObjectStorageProvider
private readonly IAiSessionContextAccessor _session;

private int GetTenantID() => _session.CurrentRequestSession.TenantID;
```

WI-03 (which was "modify `BizFirst.Ai.Octopus.Abstraction`") is now replaced by
"create `BizFirst.Ai.InfraHub.Storage.Domain`". Nothing is added to Octopus.Abstraction.
