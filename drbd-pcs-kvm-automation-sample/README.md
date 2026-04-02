# DRBD/PCS/KVM OCI Automation (Terraform + Ansible)

## Purpose

This directory provisions OCI infrastructure across two regions and configures a DRBD + Pacemaker/Corosync (PCS) + KVM stack.

Provisioning is Terraform-driven (`main.tf` + modules in `modules/`), and configuration management is Ansible-driven (`ansible/`), executed from Terraform via `modules/ansible/main.tf`.

## High-Level Flow (Terraform -> Ansible)

1. Terraform generates an SSH keypair (`tls_private_key.stack_key`) and writes private key `id_rsa`.
2. Terraform creates region1 and region2 networking (`modules/network`), including DRGs.
3. Terraform creates inter-region remote peering (`modules/remote-peering`).
4. Terraform creates DNS view/zone in region1 (`modules/dns`).
5. Terraform creates compute + block volumes in both regions (`modules/instances`), with cloud-init from `userdata/linux_mount.sh`.
6. Terraform runs `module.ansible_run` (`modules/ansible/main.tf`), which:
   - generates `ansible/inventory.yml` from `ansible/inventory.tpl`,
   - generates `ansible/roles/pcs_primary/defaults/main.yml` from `ansible/roles/pcs_primary/defaults/main.tpl`,
   - selects bastion by tag `freeform_tags.role == "bastion"`,
   - writes `/tmp/ansible-secrets.json` on bastion,
   - uploads `ansible.zip`,
   - installs `ansible-core` on bastion and runs `ansible-playbook playbooks/main.yml -i inventory.yml -e @/tmp/ansible-secrets.json`.

Notes on ordering:
- DNS (`module.dns_region1`) depends on remote peering.
- Instances and DNS can be created in parallel.
- Ansible waits for both instances (explicit `depends_on`) and DNS output references used in generated defaults.

## Ansible Execution Order and Why

`ansible/playbooks/main.yml` imports playbooks in this order:

1. `kvm_bootstrap.yml`: ensure KVM/libvirt packages/services exist before VM definition.
2. `drbd_bootstrap.yml`: install/configure DRBD on all DRBD nodes.
3. `drbd_primary.yml`: promote/format/mount DRBD on designated primary node(s).
4. `pcs_bootstrap.yml`: install/prepare cluster tooling and custom DNS resource agent.
5. `kvm_primary.yml`: place VM image, define VM XML on all KVM nodes, start VM on primary.
6. `pcs_primary.yml`: configure cluster resources and ordering/colocation constraints.

## Main Terraform Components

- `main.tf`: provider aliases, module wiring, key generation, Ansible trigger.
- `variables.tf`: input contract for network/compute/DNS and sensitive values.
- `output.tf`: instance IPs and generated SSH public key.
- `modules/network/main.tf`: VCN, IGW/NGW/SGW, routes, security lists, subnets, DRGs, DRG attachments.
- `modules/remote-peering/main.tf`: requestor/acceptor RPC setup.
- `modules/dns/main.tf`: DNS view + zone + resolver view attachment.
- `modules/instances/main.tf`: OCI instances, block volumes, attachments, user-data mount script, bastion key copy.
- `modules/ansible/main.tf`: inventory/default generation + remote Ansible execution on bastion.

## Main Ansible Components

- Inventory and grouping:
  - `ansible/inventory.tpl` creates `drbd_nodes`, `pcs_nodes`, `kvm_nodes`, and `primary_*` groups from instance freeform tags.
  - Primary groups are selected by tags `drbd_role`, `pcs_role`, and `kvm_role`.
- Shared vars:
  - `ansible/group_vars/all.yml` defines DRBD device/path/port, cluster name, quorum/stonith defaults.
- Roles:
  - `kvm_bootstrap`: package upgrades, repo enablement, KVM/libvirt install, virt daemon/socket enablement.
  - `drbd`: Linbit node registration script, DRBD packages/sysctl/firewall/resource config/bootstrap/service bring-up.
  - `drbd_primary`: primary promotion, bitmap reset, filesystem creation, fstab update, mount.
  - `pcs_bootstrap`: hosts file update, PCS stack install, SELinux permissive, firewalld HA service, cluster user password, custom OCF agent install.
  - `kvm_primary`: Fedora qcow2 download/resize, libvirt XML generate/sync, VM definition on all KVM nodes, VM start on primary.
  - `pcs_primary`: cluster auth/setup/start/enable, cluster properties, DRBD/FS/DNS/VirtualDomain resources, constraint rules.
- Custom resource agent:
  - `ansible/roles/pcs_bootstrap/files/oci-dns-update` updates/deletes OCI DNS A records via OCI CLI with instance principal auth.

## Required Tools, Dependencies, Runtime Assumptions

- Terraform with OCI provider `hashicorp/oci` version `7.25.0` (declared in modules).
- The Terraform execution environment (ORM job runner or local machine) needs `ssh`, `scp`, and `zip` (used by `local-exec` in `modules/ansible/main.tf`).
- Bastion host:
  - is expected to be reachable via SSH as `opc`,
  - is expected to allow `sudo`,
  - can install `ansible-core` with `dnf`,
  - has `unzip`,
  - can reach target private IPs in `ansible/inventory.yml`.
- When this stack is deployed end-to-end with the included Terraform modules, bastion-to-node network paths are provisioned by the automation itself.
- Target nodes are expected to support commands/packages used by roles (`dnf`, `firewall-cmd`, `pcs`, `virsh`, `virt-install`, `systemd`).
- `ansible/requirements.yml` collection installation is run on bastion (`ansible.posix`).

## IAM / DNS Prerequisites (Instance Principal)

The DNS resource agent uses OCI instance principals (`--auth instance_principal`) for DNS API calls. Before deployment, create a dynamic group matching instances in the deployment compartment, for example:

`ALL {instance.compartment.id = '<compartment-ocid>'}`

Required policy statements:

- `Allow dynamic-group <domain-name>/<dynamic-group-name> to use dns-zones in compartment <your-compartment>`
- `Allow dynamic-group <domain-name>/<dynamic-group-name> to manage dns-records in compartment <your-compartment>`

## Secrets and Authentication Expectations

- Sensitive Terraform inputs in `variables.tf`:
  - `linbit_username`
  - `linbit_password`
  - `linbit_cluster_id`
  - `pcs_password`
- These are written as JSON to `/tmp/ansible-secrets.json` on bastion before playbook run.
- Terraform-generated `id_rsa` is copied to bastion (`modules/instances/main.tf`).
- Host key checking is disabled in several execution paths (`ansible/ansible.cfg` and SCP flags in `modules/ansible/main.tf`).

## How To Run

This stack is designed to be run through OCI Resource Manager (ORM), not as a standalone local Ansible runbook.

Recommended flow:

1. Create/update an ORM stack from this directory.
2. Provide stack variables in the ORM form (grouped by `schema.yaml`), including sensitive Linbit/PCS fields.
3. Run an ORM `Apply` job.
4. During the apply, Terraform provisions infrastructure and then executes Ansible automatically via `module.ansible_run`.

If you run Terraform locally instead of ORM, behavior is the same: Ansible is triggered from Terraform apply, but ORM is the intended operating model for this repository.

## How To Reuse / Re-Run

- Reuse with different topology by changing:
  - `instance_params_region1` / `instance_params_region2` tags and sizing,
  - network and block volume maps,
  - `pcs_drbd_dns_details`.
- If running Ansible outside Terraform, ensure generated files exist:
  - `ansible/inventory.yml`
  - `ansible/roles/pcs_primary/defaults/main.yml`
- `null_resource.send_to_bastion` has no explicit `triggers`; Ansible may not rerun automatically on every apply unless the resource is replaced.

## Important Side Effects and Destructive Actions

- KVM bootstrap upgrades installed packages system-wide.
- PCS bootstrap sets SELinux permissive immediately and persistently.
- DRBD/PCS roles modify firewalld runtime and permanent rules.
- DRBD roles edit `/etc/fstab`.
- PCS primary sets cluster properties:
  - `stonith-enabled=false`
  - `no-quorum-policy=ignore`
- DNS resource can update or delete RRsets depending on `dns_unregister_on_stop`.

## File/Folder Structure Summary

- `main.tf`, `variables.tf`, `output.tf`, `terraform.tfvars`: root stack and inputs/outputs.
- `modules/network`: OCI network primitives and DRG attachment.
- `modules/remote-peering`: region-to-region DRG peering.
- `modules/dns`: DNS view/zone/resolver linkage.
- `modules/instances`: compute, storage, cloud-init, bastion key copy.
- `modules/ansible`: generated Ansible files and remote execution.
- `ansible/playbooks`: orchestration entrypoints.
- `ansible/roles`: DRBD/PCS/KVM role implementations.
- `userdata/linux_mount.sh`: cloud-init helper for block storage discovery/mount preparation.
- `schema.yaml`: OCI Resource Manager form grouping metadata.

## Troubleshooting (Based on Current Implementation)

- If no bastion is found or more than one is found, verify exactly one instance has `freeform_tags.role = "bastion"`.
- If primary playbooks appear skipped, check `drbd_role`, `pcs_role`, `kvm_role` tag values in instance definitions.
- If DNS resource fails in Pacemaker, validate dynamic group and policies above, and verify `pcs_drbd_dns_details.dns_object_name` matches an object key in `dns_params_region1`.
- If VM tasks fail, check that libvirt tooling (`virsh`, `virt-install`) and default libvirt networking are present.
- If DRBD tasks fail, verify `drbd_disk` and `device_disk_mappings` match attached devices on each node.
- If Ansible archive execution fails on bastion, verify `unzip` and outbound package access for `dnf`.

## Open Questions / Assumptions

- `modules/dns/main.tf` references `each.value.view_display_name`, while `modules/dns/variables.tf` defines `dns_view_name` and `dns_view`.
