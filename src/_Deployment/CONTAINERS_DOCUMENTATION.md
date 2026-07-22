# BizFirst MinIO Deployment - Container Documentation

## Overview

This deployment consists of multiple Docker containers orchestrated by Docker Compose and scheduled by Ofelia. The system is designed to provide redundant backup storage with automated daily backups of three critical data sources: MinIO files, SQL Server, and PostgreSQL.

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                      SERVER A (Production)                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────────────┐  ┌──────────────────────────────────┐  │
│  │  bizfirst-primary    │  │   Backup Services (run daily)    │  │
│  │  (MinIO Storage)     │  │                                  │  │
│  │  :9000 :9001         │  │ ┌────────────────────────────┐   │  │
│  │                      │  │ │ bizfirst-backup-minio      │   │  │
│  │ Production data      │  │ │ (restic backup of /data)   │   │  │
│  │ buckets              │  │ └────────────────────────────┘   │  │
│  └──────────────────────┘  │                                  │  │
│                             │ ┌────────────────────────────┐   │  │
│  ┌──────────────────────┐  │ │ bizfirst-backup-sqlserver  │   │  │
│  │  bizfirst-postgres   │  │ │ (SQL Server → restic)      │   │  │
│  │  (PostgreSQL)        │  │ └────────────────────────────┘   │  │
│  │  :5432               │  │                                  │  │
│  └──────────────────────┘  │ ┌────────────────────────────┐   │  │
│                             │ │ bizfirst-backup-postgresql │   │  │
│  ┌──────────────────────┐  │ │ (PostgreSQL → restic)      │   │  │
│  │  bizfirst-sqlserver  │  │ └────────────────────────────┘   │  │
│  │  (SQL Server)        │  │                                  │  │
│  │  :1433               │  │ ┌────────────────────────────┐   │  │
│  └──────────────────────┘  │ │ bizfirst-backup-scheduler  │   │  │
│                             │ │ (Ofelia - runs at 2 AM)    │   │  │
│                             │ └────────────────────────────┘   │  │
│                             └──────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                    ↓↓↓ (Upload via restic)
                     ┌──────────────────────────────┐
                     │   SERVER B (Backup Server)   │
                     │                              │
                     │ Restic Repositories:         │
                     │ - backups-minio              │
                     │ - backups-sqlserver          │
                     │ - backups-postgresql         │
                     │                              │
                     │ (Stored on MinIO/S3 backend) │
                     └──────────────────────────────┘
```

---

## Primary Storage Containers

### 1. `bizfirst-primary` (MinIO Primary Storage)
**Image**: `minio/minio:latest`

**Purpose**: Main production data storage for the application

**Configuration**:
- **Ports**: 
  - `9000` - MinIO API (data access)
  - `9001` - MinIO Console (web UI)
- **Volumes**: `bizfirst-primary-data:/data`
- **Credentials**: 
  - User: `$MINIO_ROOT_USER` (from .env)
  - Password: `$MINIO_ROOT_PASSWORD` (from .env)

**Responsibilities**:
- Store application files and data
- Serve API requests on port 9000
- Provide web console for manual access on port 9001

**Access**: 
- API: `http://bizfirst-primary:9000`
- Console: `http://localhost:9001`

---

### 2. `bizfirst-postgres` (PostgreSQL Database)
**Image**: `postgres` (standard Docker Hub image)

**Purpose**: Relational database for application data

**Configuration**:
- **Port**: `5432` (standard PostgreSQL port)
- **Credentials**:
  - User: `$POSTGRES_USER`
  - Password: `$POSTGRES_PASSWORD`
  - Database: `$POSTGRES_DB_NAME`

**Responsibilities**:
- Store structured application data
- Handle SQL queries and transactions
- Provide data for PostgreSQL backups

**Notes**: 
- This container is external to this compose file (you manage it separately)
- Backup service connects to it daily for backups

---

### 3. `bizfirst-sqlserver` (SQL Server Database)
**Image**: `mcr.microsoft.com/mssql/server` (Microsoft SQL Server)

**Purpose**: SQL Server database for application data

**Configuration**:
- **Port**: `1433` (standard SQL Server port)
- **Credentials**:
  - User: `SA` (System Administrator)
  - Password: `$SQLSERVER_PASSWORD`
  - Database: `$SQLSERVER_DB_NAME`

**Responsibilities**:
- Store SQL Server data
- Handle T-SQL queries and transactions
- Provide data for SQL Server backups

**Notes**:
- This container is external to this compose file
- Only SA account is used for backups (required by SQL Server)

---

## Backup Service Containers

### 4. `bizfirst-backup-minio` (MinIO Data Backup)
**Image**: `mcr.microsoft.com/mssql-tools:latest`

**Purpose**: Backs up the entire MinIO data directory using restic

**Schedule**: Daily at **2:00 AM** (via Ofelia)

**Configuration**:
- **Volumes**:
  - Mounted from `bizfirst-primary:/data` (read-only access to MinIO data)
  - `bizfirst-backup-data:/backups` (restic cache)
- **Environment**:
  - `RESTIC_REPOSITORY`: S3-compatible backend (MinIO on Server B)
  - `RESTIC_PASSWORD`: Encryption password for backups
  - AWS credentials for S3 access

**Backup Process**:
```
1. Container starts (triggered by Ofelia at 2:00 AM)
2. Installs restic (if not already available)
3. Initializes restic repository on Server B (if first run)
4. Runs: restic backup /data --tag minio-primary
5. Applies retention policy: keep 7 daily, 4 weekly, 12 monthly
6. Cleans up old snapshots
7. Container exits
```

**What Gets Backed Up**:
- All files in `/data` (MinIO bucket data)
- Complete snapshot of production MinIO state

**Storage Location**: `s3:http://backup-server:9000/backups-minio`

---

### 5. `bizfirst-backup-sqlserver` (SQL Server Database Backup)
**Image**: `mcr.microsoft.com/mssql-tools:latest`

**Purpose**: Backs up SQL Server database using native backup format

**Schedule**: Daily at **2:10 AM** (via Ofelia, staggered)

**Configuration**:
- **Volumes**: `bizfirst-backup-data:/backups` (temporary storage)
- **Environment**:
  - `SQLSERVER_HOST`: SQL Server hostname/IP
  - `SQLSERVER_SA_PASSWORD`: SA account password
  - `SQLSERVER_DB_NAME`: Database to backup
  - `RESTIC_REPOSITORY`: S3-compatible backend

**Backup Process**:
```
1. Container starts (triggered by Ofelia at 2:10 AM)
2. Installs restic and other tools
3. Creates SQL Server backup:
   - Runs: sqlcmd -Q "BACKUP DATABASE [name] TO DISK='/tmp/sqlserver_timestamp.bak'"
   - Generates .bak file (native SQL Server format)
4. Stores backup with restic:
   - Runs: restic backup /tmp/sqlserver_timestamp.bak --tag sqlserver
5. Applies retention policy
6. Deletes temporary .bak file
7. Container exits
```

**What Gets Backed Up**:
- Complete SQL Server database (.bak format)
- Can be restored directly to SQL Server if needed

**Storage Location**: `s3:http://backup-server:9000/backups-sqlserver`

**Why Restic?**:
- Restic handles compression, deduplication, and encryption
- Multiple versions stored (retention policy)
- Can retrieve any historical backup
- Incremental backups save space

---

### 6. `bizfirst-backup-postgresql` (PostgreSQL Database Backup)
**Image**: `mcr.microsoft.com/mssql-tools:latest`

**Purpose**: Backs up PostgreSQL database using pg_dump

**Schedule**: Daily at **2:20 AM** (via Ofelia, staggered)

**Configuration**:
- **Volumes**: `bizfirst-backup-data:/backups` (temporary storage)
- **Environment**:
  - `POSTGRES_HOST`: PostgreSQL hostname/IP
  - `POSTGRES_USER`: Database user
  - `POSTGRES_PASSWORD`: User password
  - `POSTGRES_DB_NAME`: Database to backup
  - `RESTIC_REPOSITORY`: S3-compatible backend

**Backup Process**:
```
1. Container starts (triggered by Ofelia at 2:20 AM)
2. Installs restic and postgresql-client
3. Creates PostgreSQL backup:
   - Runs: pg_dump -h host -U user dbname | gzip > /tmp/postgres_timestamp.sql.gz
   - Generates compressed SQL dump (.sql.gz)
4. Stores backup with restic:
   - Runs: restic backup /tmp/postgres_timestamp.sql.gz --tag postgresql
5. Applies retention policy
6. Deletes temporary .sql.gz file
7. Container exits
```

**What Gets Backed Up**:
- Complete PostgreSQL database as SQL statements
- Compressed with gzip (reduces size by ~80%)
- Can be restored with: `psql < dump.sql`

**Storage Location**: `s3:http://backup-server:9000/backups-postgresql`

**Why Restic?**:
- Handles versioning and retention
- Encrypts backups in transit and at rest
- Deduplicates identical data across snapshots
- Space-efficient incremental storage

---

## Scheduler Container

### 7. `bizfirst-backup-scheduler` (Ofelia)
**Image**: `mcuadros/ofelia:latest`

**Purpose**: Orchestrates backup jobs on a schedule

**Configuration**:
- **Volumes**:
  - `/var/run/docker.sock` (access to Docker daemon)
  - `./ofelia.ini` (job configuration)
- **Reads**: `ofelia.ini` for job schedules and configuration

**Responsibilities**:
- Monitors system clock
- At scheduled times, restarts backup services
- Logs job execution and errors

**Schedule Configuration** (`ofelia.ini`):
```ini
[job-service-restart "backup-minio"]
schedule  = 0 2 * * *         # 2:00 AM daily
service   = bizfirst-backup-minio

[job-service-restart "backup-sqlserver"]
schedule  = 10 2 * * *        # 2:10 AM daily
service   = bizfirst-backup-sqlserver

[job-service-restart "backup-postgresql"]
schedule  = 20 2 * * *        # 2:20 AM daily
service   = bizfirst-backup-postgresql
```

**How It Works**:
1. Monitors the schedule from `ofelia.ini`
2. When schedule time arrives, restarts the specified service
3. Service's entrypoint runs the backup logic
4. After backup completes, container exits
5. Ofelia logs success/failure to `on-error` handler

---

## Initialization Containers (One-time Setup)

### 8. `bizfirst-primary-init` (MinIO Bucket Setup)
**Image**: `minio/mc:latest`

**Purpose**: Initialize buckets and permissions on primary MinIO

**Runs**: Once after `bizfirst-primary` becomes healthy

**Tasks**:
- Configure MinIO client (`mc`)
- Create bucket: `bizfirst-files`
- Set bucket permissions to private (none)
- Exits after completion

---

### 9. `bizfirst-hotstandby-setup` (Hot Standby Replication)
**Image**: `minio/mc:latest`

**Purpose**: Configure site replication from primary to hot standby

**Runs**: Once after `bizfirst-hotstandby` becomes healthy

**Tasks**:
- Configure replication from primary → hotstandby
- All changes to primary are replicated to standby
- Provides failover capability

---

### 10. `bizfirst-compliance-init` (WORM Bucket Setup)
**Image**: `minio/mc:latest`

**Purpose**: Initialize compliance/legal-hold buckets

**Runs**: Once after `bizfirst-compliance` becomes healthy

**Tasks**:
- Create WORM (Write-Once-Read-Many) buckets
- Set retention policies:
  - `bizfirst-worm`: COMPLIANCE mode, 7-year retention
  - `bizfirst-legal-hold`: GOVERNANCE mode, 1-year retention

---

### 11. `bizfirst-pitr-init` (Point-in-Time Recovery Setup)
**Image**: `minio/mc:latest`

**Purpose**: Enable versioning for point-in-time recovery

**Runs**: Once after `bizfirst-pitr` becomes healthy

**Tasks**:
- Create versioned bucket: `bizfirst-versioned`
- Enable object versioning
- Allows restore to any historical point in time

---

## Storage Containers

### 12. `bizfirst-hotstandby` (Hot Standby MinIO)
**Image**: `minio/minio:latest`

**Purpose**: Real-time replica of primary MinIO for failover

**Configuration**:
- **Ports**: `9010` (API), `9011` (Console)
- **Volumes**: `bizfirst-hotstandby-data:/data`

**Purpose**: If primary fails, hotstandby can take over immediately

---

### 13. `bizfirst-archival` (Long-term Backup Storage)
**Image**: `minio/minio:latest`

**Purpose**: Archive old backups with automatic tier transitions

**Configuration**:
- **Ports**: `9020` (API), `9021` (Console)
- **Volumes**: `bizfirst-archival-data:/data`
- **Lifecycle Policies**:
  - Transition to GLACIER after 90 days (lower cost)
  - Expiration after 10 years (3650 days)

---

### 14. `bizfirst-compliance` (Compliance Storage)
**Image**: `minio/minio:latest`

**Purpose**: WORM and legal-hold storage for regulatory compliance

**Configuration**:
- **Ports**: `9030` (API), `9031` (Console)
- **Volumes**: `bizfirst-compliance-data:/data`
- **Buckets**:
  - `bizfirst-legal-hold`: Can be placed under legal hold (1-year minimum)
  - `bizfirst-worm`: Immutable for 7 years

---

### 15. `bizfirst-pitr` (Point-in-Time Recovery Storage)
**Image**: `minio/minio:latest`

**Purpose**: Versioned storage for historical recovery

**Configuration**:
- **Ports**: `9040` (API), `9041` (Console)
- **Volumes**: `bizfirst-pitr-data:/data`
- **Features**: Object versioning enabled for all backups

---

## Monitoring Container

### 16. `bizfirst-watchdog` (Health Monitor)
**Image**: `alpine:latest`

**Purpose**: Monitor health of primary and standby MinIO

**Behavior**:
- Continuously checks both servers every 30 seconds
- Logs health status (PRIMARY: OK/FAIL, HOTSTANDBY: OK/FAIL)
- Alerts if PRIMARY is DOWN and HOTSTANDBY is UP
- Enables manual failover decision

**Output**:
```
2024-07-16T02:00:00Z [PRIMARY] OK
2024-07-16T02:00:00Z [HOTSTANDBY] OK
2024-07-16T02:00:30Z [PRIMARY] OK
2024-07-16T02:00:30Z [HOTSTANDBY] OK
2024-07-16T02:01:00Z [PRIMARY] FAIL
2024-07-16T02:01:00Z [HOTSTANDBY] OK
2024-07-16T02:01:00Z [ALERT] Primary is DOWN. HotStandby is UP. Manual failover required.
```

---

## Environment Variables Reference

### Critical Variables (Must Set)
- `MINIO_ROOT_USER` - MinIO root username
- `MINIO_ROOT_PASSWORD` - MinIO root password (strong)
- `RESTIC_PASSWORD` - Restic encryption password (strong)
- `SQLSERVER_PASSWORD` - SQL Server SA password
- `POSTGRES_PASSWORD` - PostgreSQL password
- `MINIO_REPLICA_ENDPOINT` - Backup server hostname/IP

### Database Variables (Optional with Defaults)
- `POSTGRES_HOST` - Default: `postgres`
- `POSTGRES_PORT` - Default: `5432`
- `POSTGRES_USER` - Default: `postgres`
- `POSTGRES_DB_NAME` - Default: `postgres`
- `SQLSERVER_HOST` - Default: `sqlserver`
- `SQLSERVER_PORT` - Default: `1433`
- `SQLSERVER_DB_NAME` - Default: `master`

---

## Backup Retention Policy

**Default Configuration** (in all backup services):
```bash
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
```

**Keeps**:
- 7 most recent daily backups
- 4 weekly backups (one per week)
- 12 monthly backups (one per month)

**Example Timeline**:
- Days 1-7: All daily backups kept
- Week 2: Oldest daily deleted, week 1 kept as weekly
- Month 2: Oldest weekly deleted, month 1 kept as monthly
- Year 2: Oldest monthly deleted, year 1 kept

**Adjusting Retention**: Edit the `restic forget` command in each backup service's entrypoint

---

## Logging & Monitoring

### View Backup Logs
```bash
# View backup-minio logs
docker-compose logs --tail 50 bizfirst-backup-minio

# View backup-sqlserver logs
docker-compose logs --tail 50 bizfirst-backup-sqlserver

# View backup-postgresql logs
docker-compose logs --tail 50 bizfirst-backup-postgresql

# View scheduler logs
docker-compose logs --tail 50 bizfirst-backup-scheduler
```

### Check Backup Status
```bash
# List recent MinIO backup snapshots
docker-compose exec bizfirst-backup-minio \
  restic snapshots --last 5

# List recent SQL Server backups
docker-compose exec bizfirst-backup-sqlserver \
  restic snapshots --last 5

# List recent PostgreSQL backups
docker-compose exec bizfirst-backup-postgresql \
  restic snapshots --last 5
```

---

## Disaster Recovery

### Restore from MinIO Backup
```bash
docker-compose exec bizfirst-backup-minio \
  restic restore latest --target /restore
```

### Restore from SQL Server Backup
```bash
# Get the backup file from restic
docker-compose exec bizfirst-backup-sqlserver \
  restic restore latest:tmp --target /tmp

# Restore to database
docker-compose exec bizfirst-sqlserver \
  sqlcmd -U SA -P password \
  -Q "RESTORE DATABASE [dbname] FROM DISK='/tmp/sqlserver_*.bak' WITH REPLACE"
```

### Restore from PostgreSQL Backup
```bash
# Get the backup file from restic
docker-compose exec bizfirst-backup-postgresql \
  restic restore latest:tmp --target /tmp

# Restore to database
docker-compose exec bizfirst-postgres \
  psql -U postgres dbname < /tmp/postgres_*.sql
```

---

## Troubleshooting

### Backup Didn't Run
1. Check Ofelia scheduler logs: `docker-compose logs bizfirst-backup-scheduler`
2. Verify schedule in `ofelia.ini` (cron format: `0 2 * * *` = 2:00 AM)
3. Check if backup service crashed: `docker-compose logs bizfirst-backup-minio`

### Backup Failed to Upload
1. Verify Server B is reachable: `docker-compose exec bizfirst-backup-minio ping backup-server`
2. Check restic repository: `restic ls`
3. Verify S3 credentials in environment variables
4. Check Server B disk space: `du -sh /data/minio-archival/`

### Restic Repository Corrupted
1. Re-initialize: `restic init` (will create new repo)
2. Previous backups will be lost - requires backup from other source
3. Consider running manual backup immediately after

### Container Won't Start
1. Check Docker logs: `docker-compose logs container-name`
2. Verify all volumes exist and have correct permissions
3. Check if required databases are running and accessible
4. Verify environment variables are set in `.env`

---

## Summary

| Container | Purpose | Schedule | Storage |
|-----------|---------|----------|---------|
| bizfirst-primary | Production MinIO | Always running | Primary data |
| bizfirst-postgres | PostgreSQL DB | Always running | Database |
| bizfirst-sqlserver | SQL Server DB | Always running | Database |
| bizfirst-backup-minio | Backup MinIO | 2:00 AM daily | Restic (Server B) |
| bizfirst-backup-sqlserver | Backup SQL Server | 2:10 AM daily | Restic (Server B) |
| bizfirst-backup-postgresql | Backup PostgreSQL | 2:20 AM daily | Restic (Server B) |
| bizfirst-backup-scheduler | Schedule jobs | Always running | Orchestration |
| bizfirst-hotstandby | Failover replica | Always running | Replicated |
| bizfirst-archival | Long-term archival | Always running | Archive |
| bizfirst-compliance | Compliance storage | Always running | WORM |
| bizfirst-pitr | Point-in-time recovery | Always running | Versioned |
| bizfirst-watchdog | Health monitor | Always running | Monitoring |
