# Prometheus Token Generation

## Primary Storage
```bash
docker run --rm --network network_Demo --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set primary http://bizfirst-storage-server-primary:9000 bizfirst bizfirst123 && mc admin prometheus generate primary"
```

## Hot Standby
```bash
docker run --rm --network network_Demo --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set standby http://bizfirst-storage-server-hotstandby:9000 bizfirst-standby bizfirst-standby123 && mc admin prometheus generate standby"
```

## Archival Storage
```bash
docker run --rm --network network_Demo --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set archival http://bizfirst-storage-server-archival:9000 bizfirst-archive bizfirst-archive123 && mc admin prometheus generate archival"
```

## Compliance & Retention
```bash
docker run --rm --network network_Demo --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set compliance http://bizfirst-storage-server-compliance:9000 bizfirst-compliance bizfirst-compliance123 && mc admin prometheus generate compliance"
```

## Point-In-Time Restore (PITR)
```bash
docker run --rm --network network_Demo --entrypoint /bin/sh minio/mc:latest \
  -c "mc alias set pitr http://bizfirst-storage-server-pitr:9000 bizfirst-pitr bizfirst-pitr123 && mc admin prometheus generate pitr"
```
