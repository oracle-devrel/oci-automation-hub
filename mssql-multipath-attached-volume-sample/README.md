# OCI MSSQL: Multiple Computes + Multiple Block Volumes + RAID-0

## Purpose

This code is a simple automation aid for quickly deploying an OCI Linux or Windows compute instance, attaching block volumes with the required storage layout, and installing Microsoft SQL Server so customers can test SQL Server storage performance on OCI.

It focuses on infrastructure and operating-system storage preparation:
- compute deployment
- block volume creation and attachment
- Linux iSCSI multipath attachment
- Windows iSCSI or paravirtualized attachment
- filesystem creation, mount points, and optional RAID-0 striping
- SQL Server installation and basic SQL Server path configuration

It does **not** create SQL Server databases, schemas, tables, benchmarks, or test data. After deployment, create your own databases and run your preferred workload or benchmark tooling.

This Terraform deploys on OCI:
- One or many compute instances using `instance_params` map objects
- One or many block volumes using `bv_params` map objects
- iSCSI attachments for Linux computes
- iSCSI or paravirtualized attachments for Windows computes
- Linux cloud-init that:
  - installs Microsoft SQL Server
  - logs in iSCSI targets
  - creates/mounts filesystems
  - builds RAID-0 when 2 volumes on same instance share the same `raid0_group`
- Windows cloud-init that:
  - installs Microsoft SQL Server
  - logs in iSCSI targets when `attachment_type = "iscsi"`
  - skips iSCSI login when `attachment_type = "paravirtualized"`
  - creates standalone NTFS/ReFS volumes
  - builds RAID-0 dynamic striped volumes when 2 volumes on same instance share the same `raid0_group`

The SQL bootstrap templates are:
- Linux: `cloud-init/linux-mssql-cloud-init.tftpl`
- Windows iSCSI: `cloud-init/windows-mssql-cloud-init.tftpl`
- Windows paravirtualized: `cloud-init/windows-mssql-paravirtualized-cloud-init.tftpl`

## Files

- `provider.tf`: Terraform and OCI provider
- `main.tf`: resources, map orchestration, per-instance cloud-init rendering
- `variables.tf`: input model (`instance_params`, `bv_params`, SQL settings)
- `outputs.tf`: resource maps and iSCSI connection outputs
- `terraform.auto.linux`: Linux example input
- `terraform.auto.win`: Windows example input

## Provider Configuration

`provider.tf` defines the required Terraform and OCI provider versions and configures the OCI provider.

Current provider style:

```hcl
provider "oci" {
  config_file_profile = var.config_file_profile
}
```

This means Terraform uses the OCI CLI configuration file, normally `~/.oci/config`, and the profile specified by the `config_file_profile` variable. Before running Terraform, set `config_file_profile` in the selected example variable file to the OCI CLI profile and region you want, or make sure the referenced profile exists locally.

Example:

```hcl
config_file_profile = "ION-IAD"
```

Typical OCI CLI profile example:

```ini
[ION-IAD]
user=ocid1.user.oc1..example
fingerprint=aa:bb:cc:dd
tenancy=ocid1.tenancy.oc1..example
region=us-ashburn-1
key_file=/path/to/oci_api_key.pem
```

The Terraform variables still need:
- `config_file_profile`: OCI CLI config profile used by the provider
- `tenancy_ocid`: used to look up availability domains
- `compartment_ocid`: where compute instances and block volumes are created

These are provided in the example variable files.

## Requirements

- Terraform `>= 1.5.0`
- OCI API key configured
- Existing subnet OCIDs (network is not created by this module)
- Valid image OCIDs for each instance (`linux` or `windows`)

## Key Input Model

### `instance_params` (map object)

Each map key is an instance key (`db01`, `db02`, etc.).

Required fields per instance:
- `ad`: availability domain number (`1`, `2`, `3`...)
- `os_type`: `linux` or `windows`
- `display_name`
- `shape`
- `hostname`
- `subnet_ocid`
- `image_ocid`
- `boot_volume_size_in_gbs`
- `assign_public_ip`

Optional fields:
- `ssh_public_key` (required for Linux instances)
- `nsg_ocids`
- `shape_config` (`ocpus`, `memory_in_gbs`)
- `freeform_tags`

### `bv_params` (map object)

Each map key is a block-volume key (`db01_data_a`, etc.).

Required fields per volume:
- `display_name`
- `bv_size`
- `instance_key`: target compute key from `instance_params`
- `device_name`: device path for Linux (for example `/dev/oracleoci/oraclevdb`)

Optional fields:
- `ad` (if omitted, inherits AD from target instance)
- `attachment_type` (`iscsi` or `paravirtualized`; Linux must use `iscsi`; Windows can use either)
- `vpus_per_gb`
- `use_chap`
- `raid0_group`
- `filesystem_type` (`xfs` or `ext4` for Linux; `ntfs` or `refs` for Windows)
- `mount_point` (Linux path, Windows drive letter like `D:`, or Windows mount path like `C:\Mounts\Data`)
- `freeform_tags`

## RAID-0 behavior

- A RAID-0 array is created only when exactly **2** volumes on the same instance share the same non-empty `raid0_group`.
- If a RAID group has anything other than 2 members, Terraform preconditions fail.
- For RAID groups, set the same `filesystem_type` and `mount_point` on both member volumes.
- On Windows, cloud-init creates RAID-0 as a dynamic striped volume with 64 KB allocation unit size.
- On Windows, empty or null `raid0_group` means the disk is initialized as a standalone GPT volume.
- On Windows first boot, OCI does not support the Terraform `device_name` field. The script assigns newly attached raw disks to `bv_params` entries in sorted order, so RAID-0 groups should use same-sized volumes.

## Attachment Behavior

- Linux attachment type is fixed to `iscsi`.
- Windows attachment type is selected per volume with `bv_params[*].attachment_type`.
- Do not mix `iscsi` and `paravirtualized` volumes on the same Windows instance; Terraform blocks this because cloud-init is selected per instance.
- Terraform creates `oci_core_volume_attachment` resources for each `bv_params` entry.
- For Windows instances, Terraform automatically omits the `device` attribute (OCI requires this).
- Linux cloud-init runs iSCSI login routines:
  - metadata-based login first
  - fallback discovery/login if metadata path is unavailable
- Linux computes enable the OCI Cloud Agent `Block Volume Management` plugin. This is required when OCI must automatically connect iSCSI attachments, including ultra high performance block volumes.
- Windows cloud-init enables `msiscsi`, tries OCI volume attachment metadata, and falls back to discovering Oracle iSCSI targets from OCI link-local portals before creating persistent logins.
- After iSCSI login, Windows cloud-init waits for raw iSCSI disks and applies the `bv_params` storage layout: standalone volumes for empty `raid0_group`, RAID-0 for matching non-empty `raid0_group`.
- Windows paravirtualized cloud-init does not run iSCSI commands. It waits for raw attached disks and applies the same standalone/RAID-0 storage layout.
- `enable_agent_auto_iscsi_login` controls OCI Agent automatic iSCSI login for Linux iSCSI attachments. Set it to `true` for Linux ultra high performance iSCSI volumes. Windows iSCSI attachments continue to use the Windows cloud-init manual iSCSI flow.
- Linux cloud-init applies ownership and permissions to mounted block-volume paths after mounting. By default, mount points are owned by `mssql:mssql` with mode `0770`.
- Linux SQL Server file-location defaults are applied after block volumes are mounted, so values like `/sql_data` and `/sql_backup` can be used safely.

## SQL settings

Global SQL variables are still supported:
- Linux settings prefixed with `linux_...`
- Windows settings prefixed with `windows_...`

For mixed fleets:
- Linux instances consume Linux SQL variables
- Windows instances consume Windows SQL variables

Linux volume mount permission variables:
- `linux_volume_mount_owner`: mount point owner, default `mssql`
- `linux_volume_mount_group`: mount point group, default `mssql`
- `linux_volume_mount_mode`: mount point mode, default `0770`

Linux SQL Server default path variables:
- `linux_mssql_default_data_dir`: default data file path for new databases
- `linux_mssql_default_log_dir`: default log file path for new databases
- `linux_mssql_default_backup_dir`: default backup path

## Examples

Two example variable files are included:
- `terraform.auto.linux`: deploys a Linux compute, installs SQL Server on Linux, uses iSCSI block volume attachments, and configures Linux mount points.
- `terraform.auto.win`: deploys a Windows compute, installs SQL Server on Windows, and demonstrates Windows block volume attachment and storage layout settings.

Terraform automatically loads files named `*.auto.tfvars`, but the example files are intentionally named `terraform.auto.linux` and `terraform.auto.win` so they are not both loaded at the same time.

Use one of these approaches:

```bash
terraform plan -var-file=terraform.auto.linux
terraform apply -var-file=terraform.auto.linux
```

or:

```bash
cp terraform.auto.linux terraform.auto.tfvars
terraform plan
terraform apply
```

For Windows, use `terraform.auto.win` instead.

## Run

```bash
terraform init
terraform plan -var-file=terraform.auto.linux
terraform apply -var-file=terraform.auto.linux
```

## Outputs

- `compute_instance_ids`
- `compute_private_ips`
- `compute_public_ips`
- `compute_availability_domains`
- `block_volume_ids`
- `block_volume_attachment_ids`
- `block_volume_attachment_details`
- `block_volume_attachment_iscsi`
- `windows_iscsi_attach_commands`

For Windows images where `http://169.254.169.254/opc/v2/volumeAttachments/` returns `404`, use `terraform output windows_iscsi_attach_commands` after apply. The output contains the same portal and IQN values shown by the OCI console.

## Notes

- Use consistent `device_name` values in `bv_params`; Linux cloud-init waits for these device paths. Windows ignores `device_name` because OCI does not support explicit device names for Windows volume attachments.
- For Windows, use `filesystem_type = "ntfs"` or `filesystem_type = "refs"` and set `mount_point` to a drive letter or Windows mount path.
- If you switch a Windows instance from iSCSI to paravirtualized, recreate the instance so first-boot cloud-init uses the matching template.
- Keep secrets out of version control (`linux_mssql_sa_password`, `windows_mssql_sa_password`).
