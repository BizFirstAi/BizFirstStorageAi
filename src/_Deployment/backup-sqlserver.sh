#!/bin/sh
restic init 2>/dev/null || true
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE=/tmp/sqlserver_${TIMESTAMP}.bak
LOCAL_BACKUP=/backups/sqlserver_${TIMESTAMP}.bak

/opt/mssql-tools/bin/sqlcmd -S $SQLSERVER_HOST -U SA -P "$SQLSERVER_SA_PASSWORD" -Q "BACKUP DATABASE [$SQLSERVER_DB_NAME] TO DISK='$BACKUP_FILE'"

docker cp container-sql-express:${BACKUP_FILE} ${LOCAL_BACKUP}

if [ -f "$LOCAL_BACKUP" ]; then
  restic backup $LOCAL_BACKUP --tag sqlserver
  restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
  rm -f $LOCAL_BACKUP
else
  echo "Error: Backup file not found at $LOCAL_BACKUP"
  exit 1
fi