# Compliance Retention — Design

## Responsibility

Ensure files are retained for legally required periods per tenant, and that files under
a compliance hold cannot be deleted — even by administrators — until the hold is lifted.

---

## Approach — MinIO Object Locking + Lifecycle Rules

Two mechanisms work together:

1. **Object Locking (WORM)** — prevents deletion of individual objects for a fixed period
2. **Per-tenant Lifecycle Rules** — controls expiry per tenant once the lock period ends

---

## Object Locking (WORM — Write Once Read Many)

MinIO supports S3-compatible object locking. Objects under a lock cannot be deleted or
overwritten for the duration of the lock period, even by the root admin.

**Bucket must be created with object locking enabled:**

```bash
mc mb --with-lock myminio/bizfirst-files-compliance
```

**Apply a default retention rule to the bucket:**

```bash
mc retention set --default COMPLIANCE 365d myminio/bizfirst-files-compliance
```

Modes:
- `GOVERNANCE` — admin can override with special permission
- `COMPLIANCE` — no one can override, not even root (strictest)

---

## Per-Tenant Lifecycle Rules

Different tenants may have different legal retention requirements.
Apply tenant-specific lifecycle rules on top of the base archival policy.

```bash
# Tenant 99 — 7-year financial compliance retention
mc ilm import myminio/bizfirst-files <<EOF
{
  "Rules": [
    {
      "ID":     "tenant-99-compliance",
      "Status": "Enabled",
      "Filter": { "Prefix": "tenant_99/" },
      "Expiration": { "Days": 2555 }
    }
  ]
}
EOF
```

---

## Legal Hold

A legal hold prevents deletion regardless of lifecycle policy or lock expiry.
Applied per-object when litigation is in progress.

```bash
# Place legal hold on a specific object
mc legalhold set myminio/bizfirst-files/tenant_42/bafybeig3x... on

# Remove legal hold when litigation resolves
mc legalhold set myminio/bizfirst-files/tenant_42/bafybeig3x... off
```

---

## Retention Configuration Per Tenant

Tenant retention periods should be stored in the platform's tenant configuration.
The storage service reads the retention period for the current tenant and applies it
at write time (via S3 `x-amz-object-lock-retain-until-date` header).

```csharp
// In S3FileStorageProvider.StoreFileAsync()
if (_tenantConfig.RetentionDays > 0)
{
    request.ObjectLockRetainUntilDate = DateTime.UtcNow.AddDays(_tenantConfig.RetentionDays);
    request.ObjectLockMode = ObjectLockLegalHoldStatus.On;
}
```

---

## Summary

| Mechanism | Purpose | Override possible |
|-----------|---------|-------------------|
| Object Lock GOVERNANCE | Retention with admin override | Yes (admin) |
| Object Lock COMPLIANCE | Strict retention, no override | No |
| Legal Hold | Litigation freeze | Only when removed explicitly |
| Lifecycle expiry | Auto-delete after retention period | Yes (rule change) |

---

## Related

- `Archival/design.md` — standard lifecycle archival (non-compliance)
- `Primary/design.md` — `S3FileStorageProvider` write path
