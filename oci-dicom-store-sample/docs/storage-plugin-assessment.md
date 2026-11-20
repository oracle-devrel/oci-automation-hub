# Orthanc storage-plugin assessment

## Decision

Use the official Orthanc AWS S3 Storage plugin against OCI Object Storage's
S3-compatible regional endpoint for immutable DICOM payloads, and use the
official PostgreSQL plugin only for the Orthanc index. The bucket is native OCI
Object Storage in the workload compartment; “S3-compatible” describes the API,
not a separate bucket type.

The selected Orthanc configuration is:

- `PostgreSQL.EnableIndex = true`
- `PostgreSQL.EnableStorage = false`
- `PostgreSQL.Lock = false` and `TransactionMode = ReadCommitted` for the
  required multi-writer Orthanc topology
- `AwsS3Storage.StorageStructure = flat`
- `AwsS3Storage.VirtualAddressing = false`
- a stack-managed OCI Customer Secret Key on an existing IAM user, scoped by a
  bucket-specific group policy
- a private, versioned Object Storage bucket

OCI's compatibility endpoint uses the tenancy Object Storage namespace and
region. Path-style addressing is selected because it avoids bucket-name DNS
and certificate coupling. At least two identically configured Orthanc replicas
share the managed PostgreSQL primary endpoint and Object Storage payloads, so
no pod-local DICOM volume is authoritative. The OCI PostgreSQL DB system has at
least two nodes and automatically promotes a replica on primary-node failure.

## Alternatives considered

1. PostgreSQL index and PostgreSQL storage: rejected for image payloads because
   it couples high-volume objects to database capacity, backup, and scaling.
2. Pod filesystem or block volume: rejected because it creates replica
   attachment/consistency constraints and makes pod replacement stateful.
3. A custom OCI-native Orthanc storage plugin: rejected because the supported
   S3-compatible protocol already supplies the required durable object API and
   the official plugin has retry/timeout controls.
4. OKE workload identity for S3 signing: not available for the S3-compatible
   signature flow. A dedicated Customer Secret Key is therefore required and
   must be protected as a workload secret and in Terraform state.

## Consistency and recovery boundary

Object versioning protects object history but is not an application-consistent
database backup. A usable recovery point requires a PostgreSQL backup and the
matching Object Storage object versions. Deleting or rolling back only one side
can leave index rows without payloads or unreferenced payload versions.

The acceptance test proves that an uploaded synthetic instance creates at
least one bucket object and remains retrievable through WADO-RS. The restore
drill proves that a managed PostgreSQL backup can create a separate working
database system. Production recovery must combine those two checks at the
organization's chosen point in time.

References:

- [Orthanc cloud object storage plugins](https://orthanc.uclouvain.be/book/plugins/object-storage.html)
- [Orthanc PostgreSQL plugin](https://orthanc.uclouvain.be/book/plugins/postgresql.html)
- [OCI Object Storage S3 compatibility API](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/s3compatibleapi.htm)
