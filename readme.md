# BizFirst Storage V1

📖 **[Full Documentation](https://bizfirstai.github.io/BizFirstStorageAi/)**

Enterprise-grade file storage with content-addressable deduplication and tenant isolation.

## Overview

Storage V1 is BizFirst's unified file storage system providing:
- **Content-Addressable Storage** - Files identified by SHA-256 hash (CID)
- **Automatic Deduplication** - Same file = stored once per tenant (~30% savings)
- **Tenant Isolation** - Cryptographic separation, zero cross-tenant data leakage
- **Multi-Backend Support** - MinIO, AWS S3, Cloudflare R2, Backblaze B2
- **Disaster Recovery** - restic backups + 12-month retention on Backblaze B2
- **Capacity Safeguards** - Hard stop at 90% disk usage, auto write-stop
- **Observable** - Prometheus metrics, health checks, comprehensive monitoring

## Quick Links

- **[Get Started](https://bizfirstai.github.io/BizFirstStorageAi/)** - Overview and quick start
- **[Architecture](https://bizfirstai.github.io/BizFirstStorageAi/)** - System design and data flow
- **[API Reference](https://bizfirstai.github.io/BizFirstStorageAi/)** - IObjectStorageProvider interface
- **[Deployment](https://bizfirstai.github.io/BizFirstStorageAi/)** - Setup and configuration
- **[Monitoring](https://bizfirstai.github.io/BizFirstStorageAi/)** - Health checks and Prometheus metrics

## Key Features

| Feature | Benefit |
|---------|---------|
| CID-based storage | Deterministic, deduped, integrity-verified |
| Tenant isolation | tenant_{ID}/{CID} format prevents cross-tenant access |
| Multi-backend | Configure once, deploy anywhere |
| Streaming API | Zero-copy uploads/downloads |
| Logging-safe | Raw bytes never logged, GDPR/HIPAA compliant |
| Backup & Recovery | Point-in-time restore via restic + B2 |

## Projects

- **BizFirst.Ai.InfraHub.Storage** - Implementation (S3ObjectStorageProvider)
- **BizFirst.Ai.InfraHub.Storage.Domain** - Contract (IObjectStorageProvider interface)
- **BizFirst.Integration.S3.Services** - S3 operations
- **BizFirst.Integration.S3.Domain** - S3 credentials and configuration

## License

See repository for details.
