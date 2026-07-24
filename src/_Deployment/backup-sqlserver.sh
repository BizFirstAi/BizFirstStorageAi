#!/bin/sh
set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SQL_CONTAINER="container-sql-express"
SQL_BACKUP_PATH="/tmp/bizfirst_sqlserver_backup.bak"
LOCAL_BACKUP="/backups/sqlserver_${TIMESTAMP}.bak"

restic init 2>/dev/null || true

# trigger SQL Server to write backup to its own /tmp
SQLCMD_BIN="/opt/mssql-tools18/bin/sqlcmd"
[ -f "$SQLCMD_BIN" ] || SQLCMD_BIN="/opt/mssql-tools/bin/sqlcmd"

echo "Backing up SQL Server database..."
echo "Container: $SQL_CONTAINER"
echo "Backup path in container: $SQL_BACKUP_PATH"
echo "Destination path: $LOCAL_BACKUP"

"$SQLCMD_BIN" -S "$SQLSERVER_HOST" -U SA -P "$SQLSERVER_SA_PASSWORD" \
  -Q "BACKUP DATABASE [$SQLSERVER_DB_NAME] TO DISK=N'$SQL_BACKUP_PATH' WITH FORMAT, INIT, COMPRESSION, STATS=10"

echo "Backup command completed. Checking if file exists in container..."
docker exec "$SQL_CONTAINER" ls -lah "$SQL_BACKUP_PATH"

# copy from SQL Server container to shared /backups volume
docker cp "$SQL_CONTAINER:$SQL_BACKUP_PATH" "$LOCAL_BACKUP"
echo "Backup copied to: $LOCAL_BACKUP"

if [ ! -f "$LOCAL_BACKUP" ]; then
  echo "backup file not found at $LOCAL_BACKUP"
  exit 1
fi

restic backup "$LOCAL_BACKUP" --tag sqlserver
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
rm -f "$LOCAL_BACKUP"
echo "sql server backup done: $TIMESTAMP"
