#!/bin/bash

OUTPUT_FILE="${1:-prometheus-tokens.txt}"

echo "=== Generating Prometheus Tokens for MinIO Instances ===" | tee "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# Primary Storage
echo "=== 1. Primary Storage ===" | tee -a "$OUTPUT_FILE"
docker run --rm --network network_Demo --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set primary http://bizfirst-storage-server-primary:9000 bizfirst bizfirst123 && mc admin prometheus generate primary" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# Backup Storage
echo "=== 2. Backup Storage ===" | tee -a "$OUTPUT_FILE"
docker run --rm --network network_Demo --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set backup http://bizfirst-storage-server-backup:9000 bizfirst-backup bizfirst-backup123 && mc admin prometheus generate backup" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# Hot Standby
echo "=== 3. Hot Standby ===" | tee -a "$OUTPUT_FILE"
docker run --rm --network network_Demo --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set standby http://bizfirst-storage-server-hotstandby:9000 bizfirst-standby bizfirst-standby123 && mc admin prometheus generate standby" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# Archival Storage
echo "=== 4. Archival Storage ===" | tee -a "$OUTPUT_FILE"
docker run --rm --network network_Demo --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set archival http://bizfirst-storage-server-archival:9000 bizfirst-archive bizfirst-archive123 && mc admin prometheus generate archival" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# Compliance & Retention
echo "=== 5. Compliance & Retention ===" | tee -a "$OUTPUT_FILE"
docker run --rm --network network_Demo --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set compliance http://bizfirst-storage-server-compliance:9000 bizfirst-compliance bizfirst-compliance123 && mc admin prometheus generate compliance" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

# Point-In-Time Restore (PITR)
echo "=== 6. Point-In-Time Restore (PITR) ===" | tee -a "$OUTPUT_FILE"
docker run --rm --network network_Demo --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set pitr http://bizfirst-storage-server-pitr:9000 bizfirst-pitr bizfirst-pitr123 && mc admin prometheus generate pitr" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

echo "=== Token Generation Complete ===" | tee -a "$OUTPUT_FILE"
echo "Tokens saved to: $OUTPUT_FILE" | tee -a "$OUTPUT_FILE"
