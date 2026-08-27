# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# Operator VM + OCI Bastion
#
# An optional jump/control host in the private subnet, reachable ONLY through
# the OCI Bastion service (no public IP, no open SSH from the internet). The
# use-case scripts are staged on it, and it runs with instance-principal auth
# so a user who SSHes in can submit Data Flow runs and use Object Storage with
# no API keys on the box.
#
# Connect: read the `operator_bastion_session_hint` output, run the printed
# `oci bastion session create-managed-ssh ...`, then SSH via the bastion.
###############################################################################

locals {
  create_operator = var.deploy_operator

  # Bastion names allow only letters, digits and underscores — sanitize the
  # (possibly hyphenated) resource_prefix.
  bastion_name = replace("${var.resource_prefix}-bastion", "-", "_")

  # Warm pool OCID, surfaced to the operator so created apps can attach to it.
  operator_pool_id = (
    var.deploy_dataflow && var.dataflow_create_pool
    ? oci_dataflow_pool.this[0].id
    : ""
  )

  # Bucket names only when the bucket is actually created (else empty → the
  # use-case scripts treat the capability as absent).
  operator_scripts_bucket = (
    var.deploy_dataflow && var.dataflow_create_scripts_bucket ? local.scripts_bucket_name : ""
  )
  operator_logs_bucket = (
    var.deploy_dataflow && var.dataflow_create_logs_bucket ? local.logs_bucket_name : ""
  )
  operator_warehouse_bucket = (
    var.deploy_dataflow && var.dataflow_create_warehouse_bucket ? local.warehouse_bucket_name : ""
  )

  # The operator self-pulls the use-case files from the scripts bucket at boot
  # (instance principal), so this is only possible when a scripts bucket exists.
  operator_assets_available = (
    var.deploy_operator && var.deploy_dataflow && var.dataflow_create_scripts_bucket
  )

  # When BDS and the operator are deployed together, the operator gets a
  # dedicated key for the private operator -> BDS hop. The user's deployment
  # key remains only for reaching the operator through OCI Bastion.
  operator_bds_key_enabled = var.deploy_operator && var.deploy_bds

  operator_user_data = templatefile("${path.module}/templates/operator_init.sh.tftpl", {
    resource_prefix         = var.resource_prefix
    compartment_ocid        = var.compartment_ocid
    region                  = var.region
    namespace               = local.os_namespace
    deploy_bds              = var.deploy_bds
    bds_high_availability   = var.bds_is_high_availability
    bds_secure              = var.bds_is_secure
    deploy_dataflow         = var.deploy_dataflow
    dataflow_create_pool    = var.dataflow_create_pool
    dataflow_pool_id        = local.operator_pool_id
    create_scripts_bucket   = var.deploy_dataflow && var.dataflow_create_scripts_bucket
    create_logs_bucket      = var.deploy_dataflow && var.dataflow_create_logs_bucket
    create_warehouse_bucket = var.deploy_dataflow && var.dataflow_create_warehouse_bucket
    scripts_bucket          = local.operator_scripts_bucket
    logs_bucket             = local.operator_logs_bucket
    warehouse_bucket        = local.operator_warehouse_bucket
    assets_available        = local.operator_assets_available
    bds_ssh_private_key     = local.operator_bds_key_enabled ? tls_private_key.operator_bds[0].private_key_openssh : ""
  })
}

# Purpose-specific SSH identity used only between the private operator and BDS
# nodes. The private key is installed mode 0600 on the operator by cloud-init.
# It is also present in Terraform state, so local state must be protected;
# Resource Manager protects its managed state at rest.
resource "tls_private_key" "operator_bds" {
  count = local.operator_bds_key_enabled ? 1 : 0

  algorithm = "ED25519"
}

# Latest Oracle Linux 8 image for the chosen shape.
data "oci_core_images" "operator_ol8" {
  count = local.create_operator ? 1 : 0

  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = var.operator_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Dedicated NSG so SSH (from the bastion, inside the VCN) reaches the operator
# even when an existing subnet is reused whose security list we don't control.
resource "oci_core_network_security_group" "operator" {
  count = local.create_operator ? 1 : 0

  compartment_id = var.compartment_ocid
  vcn_id         = local.vcn_id
  display_name   = "${var.resource_prefix}-operator-nsg"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group_security_rule" "operator_ssh_in" {
  count = local.create_operator ? 1 : 0

  network_security_group_id = oci_core_network_security_group.operator[0].id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = var.vcn_cidr_block
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_instance" "operator" {
  count = local.create_operator ? 1 : 0

  compartment_id      = var.compartment_ocid
  availability_domain = local.ad_name
  display_name        = "${var.resource_prefix}-operator"
  shape               = var.operator_shape

  shape_config {
    ocpus         = var.operator_ocpus
    memory_in_gbs = var.operator_memory_gbs
  }

  create_vnic_details {
    subnet_id        = local.private_subnet_id
    assign_public_ip = false
    display_name     = "${var.resource_prefix}-operator-vnic"
    hostname_label   = "operator"
    nsg_ids          = [oci_core_network_security_group.operator[0].id]
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.operator_ol8[0].images[0].id
    boot_volume_size_in_gbs = var.operator_boot_volume_gbs
  }

  # Require IMDSv2. Some tenancies enforce the imds/imds-disable-v1 limit and
  # reject instance launches when legacy metadata endpoints are left enabled.
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  # Oracle Cloud Agent + Bastion plugin are required for Managed-SSH sessions.
  agent_config {
    is_management_disabled = false
    is_monitoring_disabled = false

    plugins_config {
      name          = "Bastion"
      desired_state = "ENABLED"
    }
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.operator_user_data)
  }

  freeform_tags = merge(var.freeform_tags, { role = "operator" })

  lifecycle {
    precondition {
      condition     = length(var.ssh_public_key) > 0
      error_message = "deploy_operator = true requires ssh_public_key to be set (the key you'll use to open bastion sessions)."
    }

    # Oracle republishes the OL8 image over time; don't recreate the VM for it.
    ignore_changes = [source_details[0].source_id]
  }
}

resource "oci_bastion_bastion" "operator" {
  count = local.create_operator && var.create_bastion ? 1 : 0

  bastion_type     = "STANDARD"
  compartment_id   = var.compartment_ocid
  target_subnet_id = local.private_subnet_id
  name             = local.bastion_name

  client_cidr_block_allow_list = [for c in split(",", var.bastion_client_cidr_allow_list) : trimspace(c) if trimspace(c) != ""]
  max_session_ttl_in_seconds   = var.bastion_max_session_ttl_seconds

  freeform_tags = var.freeform_tags

  lifecycle {
    precondition {
      condition     = length([for c in split(",", var.bastion_client_cidr_allow_list) : trimspace(c) if trimspace(c) != ""]) > 0
      error_message = "create_bastion = true requires bastion_client_cidr_allow_list to list at least one client /32 (e.g. your workstation's public IP as 203.0.113.4/32)."
    }
  }
}

###############################################################################
# IAM — instance principal for the operator. Lets the VM submit Data Flow runs
# and use Object Storage without API keys. Uses the home-region provider like
# the other identity resources.
###############################################################################

resource "oci_identity_dynamic_group" "operator" {
  count    = local.create_operator_iam ? 1 : 0
  provider = oci.home

  compartment_id = var.tenancy_ocid
  name           = "${var.resource_prefix}-operator-dg-${random_string.iam_suffix[0].result}"
  description    = "Dynamic group for the ${var.resource_prefix} operator VM (instance principal)."
  matching_rule  = "ALL {instance.id = '${oci_core_instance.operator[0].id}'}"
  freeform_tags  = var.freeform_tags
}

resource "oci_identity_policy" "operator" {
  count    = local.create_operator_iam ? 1 : 0
  provider = oci.home

  # Lives in the tenancy root (like the Data Flow policy) because it grants
  # "read objectstorage-namespaces in tenancy" — a policy can only grant on its
  # own compartment subtree, and a child compartment's subtree excludes the
  # tenancy root above it. The per-compartment statements below still resolve
  # fine from here since the tenancy subtree includes every compartment.
  compartment_id = var.tenancy_ocid
  name           = "${var.resource_prefix}-operator-policy-${random_string.iam_suffix[0].result}"
  description    = "Allow the operator VM to submit Data Flow runs and use the stack's Object Storage."

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.operator[0].name} to manage dataflow-family in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.operator[0].name} to read buckets in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.operator[0].name} to manage objects in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.operator[0].name} to read objectstorage-namespaces in tenancy",
  ]

  freeform_tags = var.freeform_tags
}
