# OCI Compartment Cleaner

`oci_compartment_cleaner` discovers OCI resources in one compartment and one
region, writes a dry-run deletion plan, and can delete the planned resources
after explicit operator confirmation.

The cleaner is intended for lab, demo, proof-of-concept, temporary, or test
compartments where the expected outcome is resource removal.

This is a destructive tool. Review the dry-run plan before confirming deletion.

## Safety Model

The tool is intentionally conservative:

- It runs in dry-run mode by default.
- It always writes a deletion plan before deleting anything.
- Actual deletion requires `--execute`.
- Even with `--execute`, the operator must type exactly `DELETE`.
- Before confirmed deletion, it creates a Resource Manager discovery stack by
  default unless explicitly skipped.
- Every run writes a timestamped log file and plan files.
- Individual delete failures are logged and the run continues.
- After deletion, the tool searches again and reports resources still present in
  the compartment.

## Requirements

- Python 3.
- OCI Python SDK:


```bash
python3 --version
python3 -m pip install oci
```

- OCI permissions to inspect and delete resources in the target compartment and
  region.
- OCI Resource Manager permissions to create and read stacks in the backup stack
  compartment, unless `--skip-rm-backup-stack` is used.

Supported authentication modes:

- OCI config file and profile.
- Instance principal.
- Resource principal.

## Quick Start

By default it will use profile DEFAULT from .oci/config file.
Run a dry-run only. This is the default behavior:

```bash
python3 -m oci_compartment_cleaner \
  --compartment-id ocid1.compartment.oc1..example \
  --region eu-frankfurt-1
```

Run a dry-run, ask for confirmation, create the Resource Manager discovery
stack, and then delete only if the operator types `DELETE`:

```bash
python3 -m oci_compartment_cleaner \
  --compartment-id ocid1.compartment.oc1..example \
  --region eu-frankfurt-1 \
  --rm-backup-stack-compartment-id ocid1.compartment.oc1..backup_compartment \
  --execute
```

Skip the Resource Manager discovery stack only when this is intentional:

```bash
python3 -m oci_compartment_cleaner \
  --compartment-id ocid1.compartment.oc1..example \
  --region eu-frankfurt-1 \
  --skip-rm-backup-stack \
  --execute
```

Use a specific OCI config profile:

```bash
python3 -m oci_compartment_cleaner \
  --compartment-id ocid1.compartment.oc1..example \
  --region us-phoenix-1 \
  --config-file ~/.oci/config \
  --profile DEFAULT \
  --rm-backup-stack-compartment-id ocid1.compartment.oc1..backup_compartment \
  --execute
```

Use instance principal:

```bash
python3 -m oci_compartment_cleaner \
  --compartment-id ocid1.compartment.oc1..example \
  --region us-ashburn-1 \
  --auth instance_principal \
  --rm-backup-stack-compartment-id ocid1.compartment.oc1..backup_compartment \
  --execute
```

Show all options:

```bash
python3 -m oci_compartment_cleaner --help
```

## Optional Network Usage Audit

`network_usage_audit.py` is a standalone pre-delete audit. It does not modify
or call the cleaner. Run it separately before `oci_compartment_cleaner` when the
target compartment contains VCNs, subnets, NSGs, or local peering gateways that
might be used by resources in other compartments.

The audit is read-only. It reports accessible resources outside the target
compartment that reference target compartment network resources.

Example:

```bash
python3 network_usage_audit.py \
  --compartment-id ocid1.compartment.oc1..example \
  --region eu-frankfurt-1 \
  --config-file ~/.oci/config \
  --profile DEFAULT
```

Scan only selected external compartments:

```bash
python3 network_usage_audit.py \
  --compartment-id ocid1.compartment.oc1..example \
  --region eu-frankfurt-1 \
  --scan-compartment-id ocid1.compartment.oc1..external_one \
  --scan-compartment-id ocid1.compartment.oc1..external_two
```

Useful options:

- `--tenancy-id` supplies the tenancy OCID when it cannot be resolved from auth.
- `--compartment-access-level ACCESSIBLE|ANY` controls Identity compartment
  listing.
- `--include-inactive-compartments` also scans inactive compartments returned
  by Identity.
- `--no-vnic-scan` skips private IP and compute VNIC attachment checks.
- `--no-service-scan` skips service-specific scanners.
- `--zero-exit-on-findings` exits 0 even when findings exist.
- `--debug` enables debug logging.

Audit output files are written under `delete_runs/` by default:

```text
network_usage_audit_<compartment-tail>_<region>_<YYYYMMDDTHHMMSSZ>.log
network_usage_audit_<compartment-tail>_<region>_<YYYYMMDDTHHMMSSZ>.json
network_usage_audit_<compartment-tail>_<region>_<YYYYMMDDTHHMMSSZ>.txt
```

The script exits with code `2` when findings are reported, unless
`--zero-exit-on-findings` is supplied.

Audit flow:

```text
Parse options and configure authentication
  -> discover target VCNs, subnets, NSGs, and local peering gateways
  -> discover accessible external compartments
  -> scan Compute VNIC attachments once per external compartment
  -> cache matching VNIC attachments by VNIC OCID
  -> scan private IPs in target subnets and reuse the VNIC attachment cache
  -> scan DRG attachments and local peering gateways
  -> scan common services for subnet, VCN, or NSG references
  -> write JSON, text, and log reports
```

Implemented audit scanners currently include:

- Compute VNIC attachments.
- Private IPs and VNICs in target subnets.
- DRG attachments.
- Local peering gateways.
- API Gateway.
- Bastion.
- Functions applications.
- Load Balancer and Network Load Balancer.
- File Storage mount targets.
- Oracle Database DB systems and Autonomous Databases.
- MySQL DB systems.
- PostgreSQL DB systems.
- Container Instances.
- GoldenGate deployments.
- Analytics instances.
- Integration instances.

The audit logs each selected compartment, each service being scanned, each
availability domain where relevant, and each paginated OCI list call. If a run
slows down or appears blocked, the last log line should identify the service,
compartment, subnet, VNIC, or list page being processed.

`MethodsToScan.txt` is a working reference for additional OCI service methods
that may expose network references. Not every method in that file is currently
implemented by `network_usage_audit.py`.

## Output Files

Every run creates a log and two dry-run plan files under `delete_runs/` by
default.

File names include the target compartment suffix, region, and UTC timestamp:

```text
delete_compartment_<compartment-tail>_<region>_<YYYYMMDDTHHMMSSZ>.log
delete_compartment_<compartment-tail>_<region>_<YYYYMMDDTHHMMSSZ>.plan.json
delete_compartment_<compartment-tail>_<region>_<YYYYMMDDTHHMMSSZ>.plan.txt
```

Example:

```text
delete_compartment_wdmemntd54qzueqa_eu-frankfurt-1_20260713T125418Z.log
```

Change the local output directory:

```bash
--output-dir /path/to/delete_runs
```

Upload run artifacts to Object Storage after the run:

```bash
--log-bucket-name my-log-bucket
--log-bucket-namespace mynamespace
--log-object-prefix compartment-delete-runs
```

If `--log-bucket-namespace` is omitted, the cleaner resolves it with
`ObjectStorageClient.get_namespace`.

## Resource Manager Discovery Stack

Before confirmed deletion starts, the cleaner creates an OCI Resource Manager
stack that uses Resource Manager resource discovery against the target
compartment and region.

This is not a data backup. It captures Terraform-style definitions for OCI
resources supported by Resource Manager discovery.

The stack is created only after:

- `--execute` is supplied,
- the dry-run plan has been written,
- the operator types exactly `DELETE`.

The stack is stored in a separate compartment:

```bash
--rm-backup-stack-compartment-id ocid1.compartment.oc1..backup_compartment
```

The backup stack compartment must be different from the target cleanup
compartment. If the argument is missing, deletion stops before the first
resource is deleted.

The stack name includes the source compartment label, source compartment OCID
suffix, source region, and run timestamp:

```text
predelete-backup_<compartment-label>_<compartment-tail>_<region>_<YYYYMMDDTHHMMSSZ>
```

The stack is created in the cleanup region by default. To create it in another
region:

```bash
--rm-backup-stack-region us-ashburn-1
```

By default, Resource Manager discovers all supported services. To limit
discovery:

```bash
--rm-backup-services-to-discover core,database,mysql
```

If Resource Manager stack creation fails, the default behavior is to prompt:

```text
Type DELETE_WITHOUT_BACKUP to continue deletion anyway, or anything else to stop.
```

This can be made non-interactive:

```bash
--rm-backup-failure-action stop
--rm-backup-failure-action continue
```

To skip the Resource Manager discovery stack, opt out explicitly:

```bash
--skip-rm-backup-stack
```

Backup decision flow:

```text
Run cleaner
|-- no --execute
|   `-- write dry-run plan only; do not create Resource Manager stack
`-- --execute
    |-- operator does not type DELETE
    |   `-- stop; do not create Resource Manager stack
    `-- operator types DELETE
        |-- --skip-rm-backup-stack
        |   `-- skip Resource Manager stack and start deletion
        `-- backup stack enabled
            |-- backup stack compartment missing
            |   `-- stop before deletion
            |-- backup stack compartment equals target compartment
            |   `-- stop before deletion
            |-- Resource Manager stack becomes ACTIVE
            |   `-- start deletion
            `-- Resource Manager stack creation fails or times out
                |-- --rm-backup-failure-action stop
                |   `-- stop before deletion
                |-- --rm-backup-failure-action continue
                |   `-- start deletion without the stack
                `-- --rm-backup-failure-action prompt
                    |-- operator types DELETE_WITHOUT_BACKUP
                    |   `-- start deletion without the stack
                    `-- anything else
                        `-- stop before deletion
```

## End-to-End Flow

The cleaner runs through these phases:

```text
Parse options and configure authentication
  -> create run artifact paths
  -> discover resources with OCI Resource Search
  -> enrich discovery with selected direct service API calls
  -> normalize and classify resource types
  -> filter resources that should not be deleted directly
  -> sort resources by dependency-aware priority
  -> write JSON and text dry-run plans
  -> stop unless --execute is supplied
  -> require DELETE confirmation
  -> create Resource Manager discovery stack unless skipped
  -> delete resources in planned order
  -> wait for asynchronous deletes where configured
  -> search again and report remaining resources
  -> upload log and plan artifacts if configured
```

## Discovery

The first discovery source is OCI Resource Search.

Default query:

```text
query all resources where compartmentId = '<compartment_ocid>'
```

Override it with care:

```bash
--search-query "query all resources where compartmentId = '...' && lifecycleState != 'DELETED'"
```

Resource Search is paginated. The cleaner follows the `opc-next-page` response
header until all pages are read.

Resource Search can miss or lag behind some resources. The cleaner also enriches
the result with direct service API calls for known gaps, including:

- OKE clusters and node pools.
- Virtual networking resources.
- Block volume groups, volume group backups, and volume backups.
- Oracle Base Database backups.
- MySQL DB systems, backups, and configurations.

Direct API results are merged with Resource Search results by OCID.

## Planning

The cleaner does not delete resources in the order returned by Resource Search.
It builds a dependency-aware plan using the support manifest:

```text
oci_compartment_cleaner/resource_support.json
```

The manifest defines:

- resource type aliases,
- deletion priority,
- expected OCI SDK client and method,
- special pre-delete hooks,
- post-delete wait behavior,
- ownership notes,
- skip behavior.

Lower priority numbers delete first.

Examples:

- OKE clusters are handled before node pools and worker compute resources.
- Functions are deleted before Functions applications.
- API Gateway deployments are deleted before API gateways.
- Bastion sessions are deleted before bastions.
- Compute instances are terminated before network resources.
- Load balancers are deleted before subnet and VCN cleanup.
- Volume groups are deleted before standalone block volumes.
- Volume group backups are deleted before member volume backups.
- Route rules pointing to gateways are removed before deleting the gateways.
- VCNs are deleted near the end.

The dry-run plan records both resources planned for deletion and resources
skipped with a reason.

## Resources Intentionally Skipped

Some resources are not deleted directly because they are owned by another
resource or are OCI-managed defaults.

Common skips include:

- Child compartments.
- Tenancy and work request records.
- VNICs, VNIC attachments, private IPs, and public IPs.
- Boot volumes and boot volume attachments when compute termination owns
  cleanup.
- OKE worker compute instances when OKE cluster cleanup owns them.
- Oracle Base Database child resources when the parent DB system is planned.
- VCN-managed DNS resolver and DNS view resources.
- VCN-managed DNS zones.
- Default route tables, security lists, and DHCP options.
- Default or autogenerated DRG child resources.
- Default MySQL configurations.
- Individual volume backups that are members of a planned volume group backup.

## Deletion Execution

For simple resources, the cleaner uses dynamic OCI SDK discovery. At runtime it
scans the installed OCI Python SDK for client methods that:

- start with `delete_`, `terminate_`, or `detach_`,
- have exactly one required ID-like parameter.

For example:

- `Instance` -> `ComputeClient.terminate_instance`
- `Volume` -> `BlockstorageClient.delete_volume`
- `ApiDeployment` -> `DeploymentClient.delete_deployment`
- `ApiGateway` -> `GatewayClient.delete_gateway`
- `NoSQLTable` -> `NosqlClient.delete_table`

Some resources need explicit service handling because a single dynamic API call
is not enough. Those cases are implemented as focused handlers or pre-delete
hooks.

If a delete API call fails, the cleaner logs the error, records the resource,
and continues with the next resource.

## Known Resource Support

The support manifest and handlers currently cover these common OCI resource
families:

- Compute: instances, instance pools, capacity reservations.
- OKE: clusters and node pools.
- Container Instances.
- Functions: functions and applications.
- API Gateway: deployments and gateways.
- Bastion: bastions and sessions.
- Load Balancer and Network Load Balancer.
- Object Storage buckets.
- Container Registry repositories and images.
- Oracle Base Database systems and backups.
- Autonomous Database, including implemented Data Guard handling.
- MySQL DB systems, backups, and custom configurations.
- PostgreSQL DB systems and backups.
- NoSQL tables.
- DevOps repositories and projects.
- Notifications subscriptions and topics.
- Events rules.
- Disaster Recovery Protection Groups.
- File Storage file systems, mount targets, replication, and replication
  targets.
- Block Storage volumes, volume attachments, volume groups, volume backups, and
  volume group backups.
- Virtual networking resources such as VCNs, subnets, network security groups,
  non-default route tables, non-default security lists, non-default DHCP options,
  gateways, DRGs, and DRG attachments.
- Customer DNS zones.

Generate the current support table:

```bash
python3 -m oci_compartment_cleaner.support_matrix
```

The support table is the best local reference for the exact resource types,
priorities, handlers, and notes in the current code.

## Special Resource Handling

### Object Storage Buckets

Before deleting a bucket, the cleaner attempts to:

1. Delete retention rules where the API and permissions allow it.
2. Abort multipart uploads.
3. Delete object versions and delete markers.
4. Delete current objects.
5. Delete the bucket.

If a retention rule cannot be deleted or is still enforced by OCI, object
deletion can fail with `RetentionRuleViolation`, and bucket deletion can fail
with `BucketNotEmpty`.

### Compute Instances

Compute instances are terminated with:

```text
preserve_boot_volume=False
preserve_data_volumes_created_at_launch=False
```

That is why boot volumes and launch-created data volumes are normally skipped as
parent-managed artifacts.

### Compute Capacity Reservations

Capacity reservations are deleted after compute instances. If instances are
still terminating against a reservation, the cleaner waits and retries within
the configured delete wait timeout.

### Databases

Database cleanup is service-specific:

- Oracle Base Database systems are terminated at the DB system level.
- Oracle Base Database backups are deleted with the Database API.
- Autonomous Databases are deleted with the Database API.
- Autonomous Database Data Guard peers are handled where implemented, including
  standby termination when required.
- MySQL DB systems are prepared before deletion by clearing delete protection
  and setting final backup behavior to skip creating a final backup.
- MySQL backups and custom configurations are deleted where supported.
- PostgreSQL DB systems and backups use the PostgreSQL API.

### File Storage

File systems can be blocked by File Storage replication. The cleaner checks
same-compartment, same-region replication references and removes local
replication resources where implemented.

Cross-region or cross-compartment File Storage replication cleanup is not fully
implemented.

### Disaster Recovery Protection Groups

DR Protection Groups must be disassociated before deletion. The cleaner checks
for peer association, disassociates where possible, waits for the state to
clear, and then calls the delete API.

### Networking

Before deleting route-target resources such as DRGs, NAT gateways, service
gateways, internet gateways, or local peering gateways, the cleaner removes
route rules that reference the resource being deleted.

## Waits, Retries, and Verification

Some OCI delete APIs are asynchronous. The cleaner waits after delete when the
support manifest or built-in waiter logic says the resource should be waited.

Configure delete waits:

```bash
--delete-wait-timeout-seconds 1200
--delete-wait-interval-seconds 20
```

Disable delete waits:

```bash
--delete-wait-timeout-seconds 0
```

The cleaner enables the OCI SDK default retry strategy unless disabled:

```bash
--no-sdk-retry-strategy
```

It also wraps OCI SDK calls in explicit 429 retry handling:

```text
--throttle-retry-attempts 8
--throttle-retry-base-sleep-seconds 2.0
--throttle-retry-max-sleep-seconds 60.0
```

After deletion, the cleaner searches again and reports resources still returned
for the compartment.

Configure post-delete verification:

```bash
--post-delete-verification-timeout-seconds 120
--post-delete-verification-interval-seconds 20
```

Use one immediate verification scan:

```bash
--post-delete-verification-timeout-seconds 0
```

## Repository Layout

```text
oci_compartment_cleaner/
  __main__.py                 Package entry point for python -m
  cli.py                      Main command flow
  context.py                  Shared execution context
  planner.py                  Dry-run plan construction
  registry.py                 Manifest loading and handler matching
  resource_support.json       Resource support manifest
  handlers/                   Service-specific handlers and pre-delete hooks
  runtime_*.py                Focused runtime modules
  tests/                      Unit tests

README.md                     Main operator and maintainer guide
SOLUTION_OVERVIEW.md          Higher-level solution summary
MethodsToScan.txt             Working notes for possible network audit scanners
network_usage_audit.py        Standalone read-only audit for external use of
                              target compartment network resources
resource_manager_backup.py    Resource Manager discovery stack helper
delete_compartment_resources.py
                              Single-file implementation retained for
                              compatibility with existing users
```

The package implementation is the documented entry point for new usage.

## Maintaining Resource Support

Most support changes should start in:

```text
oci_compartment_cleaner/resource_support.json
```

Recommended workflow:

1. Reproduce the issue with a dry-run plan and log.
2. Identify the Resource Search type and OCID resource type.
3. Check the OCI Python SDK method needed to delete, terminate, detach, or
   schedule deletion.
4. Decide whether the resource can use generic dynamic deletion or needs a
   service-specific handler.
5. Add or update the manifest entry.
6. Add explicit wait metadata when deletion order depends on the resource being
   fully gone before the next resource is deleted.
7. Add or update a focused test.
8. Run the tests.
9. Generate the support matrix.
10. Test in a disposable compartment before using the change more broadly.

Run tests:

```bash
python3 -B -m unittest discover -s oci_compartment_cleaner/tests
```

Run the package help smoke test:

```bash
python3 -B -m oci_compartment_cleaner --help
```

Generate the support matrix:

```bash
python3 -B -m oci_compartment_cleaner.support_matrix
```

## Known Limitations and Disclaimer

This cleaner is destructive. Use it only for compartments where resource
removal is intended and approved.

Important implications:

- The cleaner tries to delete every plannable resource it discovers in the
  selected compartment and region.
- Child compartments are intentionally skipped.
- Object Storage bucket contents are deleted before bucket deletion. The cleaner
  cannot reliably determine whether objects are used by workloads or users in
  other compartments.
- The Resource Manager discovery stack is not a full data backup and is not a
  guaranteed restore plan.
- The cleaner does not fully cross-check whether resources from other
  compartments depend on resources in the target compartment.
- `network_usage_audit.py` can help identify external network dependencies
  before deletion, but it is best-effort and limited by IAM permissions and
  implemented service scanners.
- OCI delete APIs often detect dependencies and return conflicts, but this is
  not guaranteed for every dependency shape.
- Some services have cross-region relationships. Only implemented
  service-specific cases are handled.
- Some resources require schedule-delete operations, multiple identifiers,
  details objects, or manual pre-cleanup. These require explicit support.
- The operator is responsible for reviewing the dry-run plan, validating
  permissions, and confirming that deletion is intended.
- A completed run can still leave resources behind. Review the final
  verification output and log file after every run.

The software is provided as-is. The maintainers are not responsible for data
loss, service disruption, unexpected cost, security impact, or business impact
caused by use of this tool.

## Suitable Use Cases

Good fits:

- Demo and lab compartment cleanup.
- Proof-of-concept environment teardown.
- Temporary project compartment cleanup.
- Repeated test environment reset.
- Cleanup preparation before deleting an empty compartment manually.

Poor fits:

- Production compartments without manual review and approval.
- Shared network compartments used by other teams.
- Compartments with unknown application ownership.
- Environments where object, database, or volume data must be preserved.
- Regulated environments without an approved backup, retention, and change
  process.
