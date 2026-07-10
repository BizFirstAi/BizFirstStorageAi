# Archival — Design

## Responsibility

Automatically transition old files from hot storage to a cold/cheaper storage class,
and expire files that have exceeded their retention period.
Configured via MinIO Lifecycle Policies (S3-compatible).

---

## Lifecycle Policy

Files are primarily audio/document uploads. They are accessed immediately after upload
(for processing) and rarely accessed again. They are ideal for fast cold-tiering.

```
Day 0    → Stored in MinIO hot storage
Day 30   → Transitioned to cold storage class (GLACIER equivalent)
Day 365  → Expired and deleted (unless compliance hold — see ComplianceRetention)
```

---

## Lifecycle Policy JSON

```json
{
  "Rules": [
    {
      "ID":     "bizfirst-standard-lifecycle",
      "Status": "Enabled",
      "Filter": { "Prefix": "tenant_" },
      "Transition": {
        "Days":         30,
        "StorageClass": "GLACIER"
      },
      "Expiration": {
        "Days": 365
      }
    }
  ]
}
```

Save as `lifecycle.json` and apply:

```bash
mc ilm import myminio/bizfirst-files < lifecycle.json
```

Verify:

```bash
mc ilm ls myminio/bizfirst-files
```

---

## MinIO Cold Tier Setup

MinIO supports tiered storage — objects are moved to a remote backend (AWS S3 Glacier,
Backblaze B2, etc.) when transitioned. The tier must be configured before the lifecycle
policy is applied.

```bash
# Add a remote tier (Backblaze B2 as cold tier example)
mc admin tier add b2 myminio B2COLD \
  --account ${B2_KEY_ID} \
  --secret   ${B2_APP_KEY} \
  --bucket   bizfirst-cold-tier \
  --prefix   archived/

# Then reference "B2COLD" as the StorageClass in the lifecycle policy
```

---

## Per-Tenant Lifecycle

To apply different retention periods per tenant, create tenant-specific rules:

```json
{
  "Rules": [
    {
      "ID":     "tenant-99-extended",
      "Status": "Enabled",
      "Filter": { "Prefix": "tenant_99/" },
      "Expiration": { "Days": 2555 }
    }
  ]
}
```

See `ComplianceRetention/design.md` for compliance-specific retention.

---

## Related

- `ComplianceRetention/design.md` — compliance holds override expiry
- `HotStandby/design.md` — replication applies before archival
