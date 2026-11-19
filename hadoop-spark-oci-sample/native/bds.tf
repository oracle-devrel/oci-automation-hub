# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# OCI Big Data Service (managed Hadoop) cluster
###############################################################################

resource "oci_bds_bds_instance" "this" {
  count = var.deploy_bds ? 1 : 0

  compartment_id         = var.compartment_ocid
  display_name           = local.bds_display_name
  cluster_version        = var.bds_cluster_version
  cluster_profile        = var.bds_cluster_profile
  cluster_admin_password = base64encode(var.bds_cluster_admin_password)
  # The operator runs the BDS use cases, so give it a purpose-specific key
  # instead of requiring the user's workstation key through agent forwarding.
  # BDS-only deployments retain the user-supplied key for direct administration.
  cluster_public_key = var.deploy_operator ? tls_private_key.operator_bds[0].public_key_openssh : var.ssh_public_key

  is_high_availability = var.bds_is_high_availability
  is_secure            = var.bds_is_secure

  # ----- Master nodes ---------------------------------------------------------
  master_node {
    shape                    = var.bds_master_shape
    subnet_id                = local.private_subnet_id
    block_volume_size_in_gbs = var.bds_master_block_volume_gbs
    number_of_nodes          = var.bds_is_high_availability ? 2 : 1

    dynamic "shape_config" {
      for_each = can(regex("Flex$", var.bds_master_shape)) ? [1] : []
      content {
        ocpus         = var.bds_master_ocpus
        memory_in_gbs = var.bds_master_memory_gbs
      }
    }
  }

  # ----- Utility nodes (Ambari / Hue / Cloudera Manager / Zeppelin) -----------
  util_node {
    shape                    = var.bds_utility_shape
    subnet_id                = local.private_subnet_id
    block_volume_size_in_gbs = var.bds_utility_block_volume_gbs
    number_of_nodes          = var.bds_is_high_availability ? 2 : 1

    dynamic "shape_config" {
      for_each = can(regex("Flex$", var.bds_utility_shape)) ? [1] : []
      content {
        ocpus         = var.bds_utility_ocpus
        memory_in_gbs = var.bds_utility_memory_gbs
      }
    }
  }

  # ----- Worker (data) nodes --------------------------------------------------
  worker_node {
    shape                    = var.bds_worker_shape
    subnet_id                = local.private_subnet_id
    block_volume_size_in_gbs = var.bds_worker_block_volume_gbs
    number_of_nodes          = var.bds_worker_count

    dynamic "shape_config" {
      for_each = can(regex("Flex$", var.bds_worker_shape)) ? [1] : []
      content {
        ocpus         = var.bds_worker_ocpus
        memory_in_gbs = var.bds_worker_memory_gbs
      }
    }
  }

  # ----- Compute-only worker nodes (optional, for elastic Spark/YARN) ---------
  dynamic "compute_only_worker_node" {
    for_each = var.bds_compute_only_worker_count > 0 ? [1] : []
    content {
      shape                    = var.bds_compute_only_worker_shape
      subnet_id                = local.private_subnet_id
      block_volume_size_in_gbs = 150
      number_of_nodes          = var.bds_compute_only_worker_count

      dynamic "shape_config" {
        for_each = can(regex("Flex$", var.bds_compute_only_worker_shape)) ? [1] : []
        content {
          ocpus         = var.bds_compute_only_worker_ocpus
          memory_in_gbs = var.bds_compute_only_worker_memory_gbs
        }
      }
    }
  }

  # Optional bootstrap script — user-supplied Object Storage URL with a shell
  # script that BDS runs on every node at cluster creation. This is the hook
  # for customising core-site.xml, yarn-site.xml, hdfs-site.xml,
  # spark-defaults.conf, etc.
  bootstrap_script_url = var.bds_bootstrap_script_url

  # cidr_block is the Oracle-managed network BDS creates for the cluster — it
  # must NOT overlap the customer subnet the nodes attach to (var.vcn_cidr_block
  # would, since the subnet lives inside it).
  network_config {
    cidr_block              = var.bds_oracle_network_cidr
    is_nat_gateway_required = var.create_vcn ? false : true
  }

  freeform_tags = var.freeform_tags

  # The bdsprod service principal must be able to read the VCN/subnet before
  # the cluster attaches nodes, otherwise creation fails with "not enough
  # permissions to access subnet or vcn details".
  depends_on = [oci_identity_policy.bds_network]

  lifecycle {
    ignore_changes = [
      # BDS may inject extra services post-create depending on cluster profile.
      cluster_version,
      # BDS exposes the cluster SSH key only at creation. Preserve existing
      # clusters when adopting the operator key; fresh clusters receive it.
      cluster_public_key,
    ]

    precondition {
      condition     = !var.deploy_bds || length(var.ssh_public_key) > 0
      error_message = "ssh_public_key must be set when deploy_bds = true."
    }

    precondition {
      condition     = !var.deploy_bds || length(var.bds_cluster_admin_password) >= 8
      error_message = "bds_cluster_admin_password must be at least 8 characters when deploy_bds = true."
    }

    precondition {
      condition     = !var.deploy_bds || var.bds_is_high_availability == var.bds_is_secure
      error_message = "OCI BDS requires bds_is_high_availability and bds_is_secure to be logically equivalent: either both true (HA + Kerberos) or both false."
    }

    precondition {
      condition     = !var.deploy_bds || !var.create_vcn || var.bds_oracle_network_cidr != var.vcn_cidr_block
      error_message = "bds_oracle_network_cidr must not overlap the VCN/subnet. It is set equal to vcn_cidr_block; pick a non-overlapping range (default 172.16.0.0/16)."
    }
  }
}
