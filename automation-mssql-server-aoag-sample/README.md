<!-- Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved. -->
<!-- The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/ -->
# SQL Server AOAG Terraform

This folder is a region-neutral Terraform build for the OCI SQL Server AOAG lab. It follows the Oracle SQL Server AOAG tutorial concept, with the POC changes actually used here:

- The target OCI region, image, and compartment are inputs. Availability domains are selected automatically: DC/SQL1 use the first AD, and SQL2 uses the second AD when the region has one; otherwise all nodes use the first AD.
- Public subnets for DC, SQL1, and SQL2.
- No bastion.
- No NSGs.
- No OCI Load Balancer.
- Native WSFC and SQL AOAG listener secondary private IPs.
- DC can be used as the file share witness host.

Terraform in this folder creates the OCI infrastructure and can run first-boot Windows bootstrap scripts. `DC-VM` can promote itself as the first domain controller, create `domainadmin`, create the dedicated SQL service account `sqlsa`, and publish the file-share witness. `SQL1`/`SQL2` can set local Windows credentials, enable RDP, rename, point DNS to the DC, join the domain, grant `domainadmin` local admin/RDP access, install SQL Server 2025 Standard Developer plus SSMS, prepare Failover Clustering, enable Always On, have SQL1 create the configured WSFC with the DC file-share witness, restore the configured sample database with `NORECOVERY` on SQL2, create the configured availability group, synchronize the replicas, and create the configured native listener.

This is a recreate configuration, not an import of the currently stopped VMs. If you want Terraform to take ownership of the current live resources, use this as the target shape and add `terraform import` or Terraform `import` blocks before applying changes.

## Files

- `00-versions.tf` and `01-provider.tf`: Terraform and OCI provider setup.
- `02-variables.tf`: Editable inputs.
- `03-network.tf`: VCN, internet gateway, public route table, and public subnets.
- `04-security.tf`: Security lists only. No NSGs.
- `05-compute.tf`: DC, SQL1, and SQL2 Windows compute instances plus the small first-boot downloader metadata.
- `06-secondary-private-ips.tf`: WSFC and AOAG listener/private IP reservations.
- `06-sql-storage.tf`: One 100 GB paravirtualized block volume for each SQL node.
- `07-outputs.tf`: RDP IPs, private IPs, storage volume IDs, and post-provisioning values.
- `08-automation-artifacts.tf`: Private Object Storage bucket, uploaded PowerShell scripts, and object-specific PARs used by the Windows bootstraps.
- `schema.yaml`: OCI Resource Manager Stack form, including password controls for sensitive inputs.
- `terraform.tfvars.example`: Copy to `terraform.tfvars` and update before apply.
- `templates/dc-user-data.ps1.tftpl`: Thin launcher that injects the compressed DC script into `DC-VM`.
- `templates/windows-node-user-data.ps1.tftpl`: Thin first-boot downloader/launcher for `SQL1` and `SQL2`.
- `scripts/dc/01-configure-domain-controller.ps1`: DC use-case script for the configured domain, domain-admin/service accounts, and witness share.
- `scripts/sql/02-configure-sql-node.ps1`: Shared SQL node use-case script. Terraform passes `SQL1` or `SQL2` as `TargetComputerName`.
- `scripts/wsfc/03-configure-wsfc.ps1`: WSFC and Always On prep script launched by SQL1 when `auto_configure_wsfc = true`.
- `scripts/aoag/04-prepare-sample-database.ps1`: Task 5.3 sample backup/restore phase uploaded to Object Storage and downloaded only by SQL1.
- `scripts/aoag/05-configure-availability-group.ps1`: Task 5.4 endpoint/AG/replica phase plus Task 5.5 native listener creation and verification. SQL1 and SQL2 use synchronous commit and automatic failover; database seeding remains manual backup/restore.
- `scripts/aoag/06-safe-planned-failover.ps1`: Guarded planned failover/failback that waits for both replicas to return synchronized and healthy.
- `scripts/aoag/07-reconcile-availability-group.ps1`: Startup reconciliation task that waits for SQL/WSFC recovery after a VM reboot and then verifies the local replica is synchronized.
- `docs/automation-scripts.md`: Script map and manual troubleshooting examples.
- `docs/post-provisioning-runbook.md`: What to automate after Terraform.

Terraform state, local variable files, plans, and the `.terraform` directory are local/generated artifacts. They are ignored by `.gitignore`; keep the active state file if Terraform still manages deployed resources.

## Deploy Locally

Use this path only when the environment will be created and managed by Terraform on your workstation. Before continuing, install Terraform, configure an authorized OCI CLI profile in `~/.oci/config`, and select a Windows image OCID from the same OCI region as `region`.

Local Terraform and OCI Resource Manager maintain separate state. Do not run a local `terraform apply` against resources created by a Resource Manager stack. For a separate local test, first destroy the Resource Manager stack or use a different compartment with unused CIDRs and static IPs.

```bash
cd <cloned-repository-directory>
cp terraform.tfvars.example terraform.tfvars

# Review terraform.tfvars before applying. Replace every placeholder beginning
# with REPLACE_, keep intentionally blank values blank unless their comments
# say otherwise, and adjust example defaults such as CIDRs and sizing when
# needed. Keep execution_environment = "local" and set oci_config_profile to a
# profile that exists in ~/.oci/config. The region and windows_image_ocid must
# match. Then choose one credential method below. Do not use both methods for
# the same variable.

# Option A: recommended for local deployment. Passwords are not written to
# terraform.tfvars.
export TF_VAR_domain_admin_password='<domain-admin-password>'
export TF_VAR_windows_admin_password='<local-windows-password>'
export TF_VAR_sql_service_account_password='<sql-service-account-password>'

# Option B: uncomment and set domain_admin_password in the local,
# gitignored terraform.tfvars file. The other two password fields can remain
# empty to reuse the domain-admin password for this POC.

terraform init
terraform plan
terraform apply
```

The generated `terraform.tfvars` and local Terraform state are sensitive and are intentionally ignored by Git. Keep them only on the workstation that manages this deployment.

For a genuinely fresh lab test, destroy the previous stack first and then apply from this same directory:

```bash
terraform destroy
terraform apply
```

Do not delete `terraform.tfstate` before `terraform destroy`; doing so would orphan the OCI resources from Terraform's tracking.

`domain_admin_password` must be supplied before `terraform apply` when `auto_configure_domain_controller = true`. Supply it either through `TF_VAR_domain_admin_password` or in the local, ignored `terraform.tfvars` file. If `windows_admin_password` or `sql_service_account_password` is omitted or empty, Terraform reuses `domain_admin_password` for this POC.

## Deploy with OCI Resource Manager

This configuration can run as an OCI Resource Manager stack instead of from a local workstation. Resource Manager supplies OCI authentication and manages the Terraform state, so do not configure an OCI CLI profile or run `terraform init` locally for this path.

Resource Manager is an alternative deployment owner, not an extension of a local deployment. Do not switch between the two methods for the same resources unless the original owner has first destroyed its stack.

1. In the OCI Console, go to **Developer Services** > **Resource Manager** > **Stacks** and create a stack from this Git repository or from a clean ZIP of this directory.
2. Use this directory as the stack working directory. Do not include `.terraform`, any `terraform.tfstate*` file, `terraform.tfvars`, plans, or logs in the uploaded source.
3. Set `execution_environment` to `resource_manager`. Set the region, compartment, Windows image, network values, and sizing in the Stack variables page.
4. Enter `domain_admin_password` in the password field. The optional Windows and SQL service password fields may be left blank to reuse that password for this POC, or set independently. Do not use `TF_VAR_*` commands in Resource Manager.
5. Run a **Plan** job, review it, then run an **Apply** job. Use a Resource Manager **Destroy** job when removing the environment.

The Resource Manager user or group needs permission in the target compartment to manage the VCN, compute instances, boot and block volumes, private IPs, Object Storage objects/bucket, and associated networking resources. Treat the stack state and job logs as sensitive because the first-boot automation handles account passwords.

Terraform reports the public IPs when OCI has finished creating the instances. That is not the end of the Windows work: first-boot scripts continue through renames, reboots, domain promotion, SQL installation, WSFC, restores, and AOAG configuration. Wait at least 10-15 minutes after the IPs appear before testing; on a fresh deployment, allow the DC promotion cycle roughly 20-25 minutes. Do not destroy and redeploy just because the IP output appeared.

The scripts add short, logged settling pauses at the major handoffs and use readiness/retry loops for the services that must actually be available. The reliable completion signals are the marker files below, not Terraform's resource creation timestamps.

```text
DC-VM: C:\AOAGAutomation\DC\DOMAIN_READY.txt
SQL1/SQL2: C:\AOAGAutomation\Windows\WINDOWS_BOOTSTRAP_READY.txt
SQL1: C:\AOAGAutomation\WSFC\WSFC_READY.txt
SQL1/SQL2: C:\AOAGAutomation\WSFC\TASK_5_5_LISTENER_READY.txt
```

If a marker is missing, inspect the stage and the tail of the matching log before rerunning anything:

```powershell
Get-Content C:\AOAGAutomation\DC\stage.txt -ErrorAction SilentlyContinue
Get-Content C:\AOAGAutomation\DC\configure-dc.log -Tail 80
Get-Content C:\AOAGAutomation\Windows\stage.txt -ErrorAction SilentlyContinue
Get-Content C:\AOAGAutomation\Windows\windows-bootstrap.log -Tail 120
Get-Content C:\AOAGAutomation\WSFC\configure-wsfc.log -Tail 160
```

After the ready markers exist, refresh SSMS Object Explorer and run the verification queries in `docs/post-provisioning-runbook.md`.

`SQL1` and `SQL2` then complete their staged bootstrap. With `auto_install_sql_server = true`, expect the SQL nodes to take longer because they download SQL Server 2025 media and SSMS from Microsoft. Watch:

```powershell
Get-Content C:\AOAGAutomation\Windows\stage.txt
Get-Content C:\AOAGAutomation\Windows\windows-bootstrap.log -Tail 80
Get-Content C:\AOAGAutomation\Windows\WINDOWS_BOOTSTRAP_READY.txt
```

When `auto_configure_wsfc = true`, SQL1 waits for both SQL nodes, creates the cluster, and configures the witness. Watch:

```powershell
Get-Content C:\AOAGAutomation\WSFC\configure-wsfc.log -Tail 120
Get-Content C:\AOAGAutomation\WSFC\WSFC_READY.txt
Get-ClusterNode -Cluster SQLAGCLUSTER
Get-ClusterQuorum -Cluster SQLAGCLUSTER
```

Then use `terraform output` to get the public RDP IPs. The native listener uses the two reserved private IPs configured by `aoag_listener_ip_sql1` and `aoag_listener_ip_sql2`, and the port configured by `aoag_listener_port`.

Treat `terraform.tfvars`, rendered instance metadata, and Terraform state as sensitive because the first-boot automation needs Windows/domain passwords.

The PowerShell payloads are uploaded to a private Object Storage bucket because OCI limits combined instance metadata to 32 KB. Terraform creates read-only, object-specific pre-authenticated requests expiring at `automation_artifact_expiration`; refresh that variable before a later deployment after the expiry date.

The default shape sizing is 6 OCPUs and 16 GB RAM for `DC-VM`, and 8 OCPUs and 32 GB RAM for each SQL node through `sql_ocpus` and `sql_memory_in_gbs`. All boot volumes default to 100 GB. Each SQL node also receives a 100 GB local block volume, formatted as `F:` and used for SQL data, logs, and backup files. SQL binaries and SSMS remain on the boot volume.

#Post-Deployment Readiness
##Terraform completes infrastructure provisioning before guest automation finishes. Allow approximately 15-30 minutes for Active Directory promotion, domain joins, SQL Server installation, WSFC, database restore, availability group creation, listener configuration, and synchronization before testing failover.
