#!/bin/sh
restic init 2>/dev/null || true
BACKUP_FILE=/tmp/postgres_$(date +%Y%m%d_%H%M%S).sql.gz
PGPASSWORD=$POSTGRES_PASSWORD pg_dump -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER $POSTGRES_DB_NAME | gzip > $BACKUP_FILE
restic backup $BACKUP_FILE --tag postgresql
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
rm -f $BACKUP_FILE
