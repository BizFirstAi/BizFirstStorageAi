#!/bin/sh
restic init 2>/dev/null || true
restic backup /data --tag minio-primary
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
