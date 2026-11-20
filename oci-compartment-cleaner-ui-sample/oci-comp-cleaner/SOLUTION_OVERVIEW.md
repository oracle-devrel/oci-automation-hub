# OCI Compartment Cleaner - Solution Overview

## Purpose

The OCI Compartment Cleaner is a controlled cleanup utility for removing OCI
resources from one selected compartment in one selected region.

It is intended for environments such as labs, demos, proof-of-concept
compartments, temporary project compartments, and cleanup exercises where the
expected outcome is to remove the resources that still exist in the compartment.

The tool is intentionally built around safety gates:

- It runs in dry-run mode by default.
- It writes a deletion plan before deleting anything.
- Actual deletion requires `--execute` and an explicit `DELETE` confirmation.
- Before confirmed deletion, it creates a Resource Manager discovery stack by
  default, unless the operator explicitly skips that step.
- Every run writes a timestamped log and plan files.
- Individual resource failures are logged and the run continues, so one blocked
  resource does not stop cleanup of unrelated resources.

## Problem It Solves

Cleaning an OCI compartment manually is slow and error-prone because resources
have dependencies and must often be deleted in a specific order. For example,
VCNs cannot be removed while subnets, gateways, load balancers, compute
instances, bastions, or other network users still exist.

The cleaner automates the repetitive parts of this work:

- Discover resources in the target compartment.
- Build a deletion order that respects common OCI dependencies.
- Skip resources that should normally be removed by their parent resource.
- Apply service-specific cleanup where generic deletion is not enough.
- Produce logs and dry-run artifacts that can be reviewed after the run.
- Verify what remains after the delete phase.

## High-Level Flow

The tool follows the same basic lifecycle for every run.

```text
Start
  -> read target compartment, region, auth mode, and options
  -> create log and dry-run plan file names
  -> discover resources with OCI Resource Search
  -> enrich discovery with direct service API calls for known gaps
  -> normalize resource names and classify resources
  -> skip resources that should not be deleted directly
  -> sort resources into dependency-aware deletion order
  -> write dry-run plan
  -> stop unless --execute was supplied
  -> ask the operator to type DELETE
  -> create Resource Manager discovery stack unless explicitly skipped
  -> delete resources in planned order
  -> wait where needed for asynchronous deletes
  -> log errors and continue
  -> search again and report remaining resources
  -> upload artifacts to Object Storage if configured
End
```

## Main Benefits

The main value of the script is not just that it calls OCI delete APIs. Its
value is the combination of discovery, planning, safety controls, service
exceptions, and audit output.

- **Dry-run first by design**: An operator can inspect the exact deletion plan
  before deciding whether to continue.
- **Dependency-aware ordering**: Parent and dependent resources are ordered so
  common OCI conflicts are avoided.
- **Resource Manager snapshot before deletion**: Confirmed deletion creates a
  Resource Manager resource-discovery stack by default. This is not a data
  backup, but it gives operators a useful infrastructure snapshot before
  cleanup.
- **Operational audit trail**: Logs and plan files include the compartment,
  region, timestamp, resource list, delete order, skipped resources, and errors.
- **Multiple authentication modes**: The tool can run with an OCI config
  profile, instance principal, or resource principal.
- **Resilient execution**: If one resource fails, the script records the error
  and continues with the rest of the plan.
- **Post-delete verification**: The script searches again after deletion and
  reports resources still present in the compartment.
- **Maintainable package structure**: The package implementation separates resource
  support metadata, planning, execution, handlers, waiters, and tests so future
  service-specific changes are easier to add.

## How Resources Are Found

The first discovery source is OCI Resource Search. The tool searches for all
resources in the selected compartment and follows pagination until all result
pages are read.

Resource Search can sometimes lag behind service APIs or miss certain resource
types. For that reason, the script also enriches discovery with direct service
API calls for known areas such as OKE, networking, block storage groups,
database backups, and MySQL resources.

The final plan is built from the combined discovery result. Duplicate resources
are merged by OCID.

## How Deletion Is Planned

The script does not delete resources in the random order returned by Resource
Search. It classifies resources and assigns deletion priorities.

Examples of the ordering logic:

- OKE clusters are handled before worker compute resources.
- Functions are deleted before Functions applications.
- Bastion sessions are deleted before bastions.
- Compute instances are terminated before VCNs, subnets, and IP-related
  network resources.
- Load balancers are deleted before subnet and VCN cleanup.
- Volume groups and volume group backups are handled before individual member
  volumes or backups.
- Route rules pointing to gateways are removed before deleting the gateways.
- VCNs are deleted near the end, after resources that use VNICs, private IPs,
  route tables, security lists, gateways, and subnets.

Some resources are intentionally skipped because they are normally deleted by
their owning resource. Examples include VNICs, private IPs, public IPs, boot
volume attachments, and several default VCN-managed resources.

Child compartments are never deleted by this tool.

## How Deletion Is Executed

For most simple resources, the script uses the OCI Python SDK dynamically. It
looks for SDK methods such as `delete_*`, `terminate_*`, or `detach_*` that
match the resource type.

Some resources need special behavior and are handled explicitly. Examples
include:

- Object Storage buckets, where objects, object versions, delete markers,
  multipart uploads, and retention rules must be handled before bucket deletion.
- MySQL DB systems, where delete protection and final backup policy may need to
  be changed before deletion.
- Autonomous Databases with Data Guard, where standby databases or peer
  relationships may need to be handled first.
- File Storage file systems with replication references.
- Disaster Recovery Protection Groups, which must be disassociated before
  deletion.
- Compute capacity reservations, where terminating instances can temporarily
  block deletion.

For asynchronous delete operations, the script waits where supported and then
continues to the next dependency group.

## Resource Manager Snapshot

Before actual deletion starts, the script creates an OCI Resource Manager stack
using Resource Manager resource discovery. The stack is stored in a different
compartment supplied by the operator.

This step is enabled by default for actual deletion. It is skipped only if the
operator passes the explicit skip argument.

The Resource Manager stack is useful because it captures supported resource
definitions before cleanup. However, it must not be treated as a full backup or
a guaranteed restore plan.

It does not preserve data such as:

- Object Storage object contents.
- Block volume data.
- Database data.
- Secrets or credentials.
- Runtime state that Resource Manager cannot discover.

## Known Issues and Limitations

This tool is destructive. It should be used only when the intended result is to
remove resources from the selected compartment and region.

Known limitations:

- **Not a full backup solution**: The Resource Manager stack is only an
  infrastructure discovery snapshot.
- **Object contents are deleted**: Objects inside buckets are removed before
  bucket deletion. The script cannot reliably know whether those objects are
  used by workloads in other compartments.
- **Cross-compartment dependencies are not fully validated**: A resource in
  another compartment might depend on a network, bucket, DNS, or other resource
  in the target compartment. OCI usually returns a conflict when something is
  still in use, but this is not guaranteed for every dependency shape.
- **Cross-region dependencies need service-specific handling**: Some services,
  such as Autonomous Database Data Guard or File Storage replication, can have
  cross-region relationships. Only implemented cases are handled.
- **Resource Search can be delayed or incomplete**: The script compensates with
  direct service enrichment for known gaps, but Resource Search is not a perfect
  real-time inventory.
- **Not every OCI resource has a simple delete API**: Some resources require a
  schedule-delete operation, multiple identifiers, a details object, or manual
  pre-cleanup. These require explicit support in the tool.
- **Permissions matter**: The operator must have permissions to inspect and
  delete the resources. Missing permissions can look similar to missing
  resources in some OCI APIs.
- **Some OCI-managed defaults cannot be deleted**: Default VCN artifacts,
  default MySQL configurations, generated DNS resources, and other service-owned
  resources are skipped where known.
- **Failed resources may still be attempted**: If OCI returns a failed resource
  and it is not explicitly skipped, the tool may attempt to delete it.
- **A completed run can still leave resources behind**: The final verification
  output must be reviewed.

Recent examples of resource types that need explicit support rather than plain
dynamic deletion include Certificates and Certificate Authorities. Their OCI
APIs use scheduled deletion semantics instead of a simple one-ID delete call.

## Maintenance Model

The package implementation is designed so maintainers do not have to keep adding
large blocks of one-off logic to a single script.

Most day-to-day support changes should be made in the resource manifest:

- Add the OCI Resource Search type.
- Add known aliases.
- Set the deletion priority.
- Specify the expected SDK client and method.
- Mark whether the resource should wait after deletion.
- Add notes explaining ownership or dependency behavior.

If a resource has special cleanup requirements, add a small handler or
pre-delete hook instead of adding broad logic to the main execution path.

Recommended maintenance workflow:

1. Reproduce the issue with a dry-run plan and log.
2. Identify the Resource Search type and OCID resource type.
3. Check the OCI Python SDK method needed to delete or terminate it.
4. Decide whether the resource can use generic dynamic deletion or needs a
   handler.
5. Add or update the manifest entry.
6. Add a focused test.
7. Run the unit tests and generate the support matrix.
8. Test in a disposable compartment before using the change in a shared tenancy.

## Operational Recommendations

Before sharing this solution with other teams, establish clear usage rules.

- Use the tool first in dry-run mode and review the plan file.
- Run it against one compartment and one region at a time.
- Use a dedicated compartment for Resource Manager discovery stacks.
- Keep log and plan artifacts for audit and troubleshooting.
- Start with test compartments before using it on larger environments.
- Review the final verification output after every run.
- Treat skipped resources and remaining resources as part of the cleanup report,
  not as noise.
- Update the README and support matrix when new resource types are added.

## What This Tool Is Not

This tool is not:

- A full data backup solution.
- A guaranteed restore mechanism.
- A complete OCI dependency graph engine.
- A replacement for reviewing the dry-run plan.
- A tool for deleting compartments themselves.
- A tool that can safely infer application-level dependencies.

It is best understood as a controlled, auditable, extensible cleanup assistant
for OCI compartments.

## Suitable Use Cases

Good fits:

- Demo and lab compartment cleanup.
- Proof-of-concept environment teardown.
- Temporary project compartment cleanup.
- Repeated test environment reset.
- Cleanup preparation before deleting an empty compartment manually.

Poor fits:

- Production compartments without manual review.
- Shared network compartments used by other teams.
- Compartments with unknown application ownership.
- Environments where object, database, or volume data must be preserved.
- Highly regulated environments without an approved backup and change process.
