# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

data "oci_identity_users" "storage_user" {
  count    = var.create_storage_customer_secret_key ? 1 : 0
  provider = oci.home

  compartment_id = var.tenancy_id

  filter {
    name   = "email"
    values = [coalesce(var.storage_user_email, "unset@example.invalid")]
  }
}

data "oci_identity_customer_secret_keys" "storage_user" {
  count = var.create_storage_customer_secret_key ? (
    length(data.oci_identity_users.storage_user[0].users) == 1 ? 1 : 0
  ) : 0
  provider = oci.home

  user_id = local.storage_user_id
}

resource "oci_identity_group" "orthanc" {
  count    = var.create_storage_customer_secret_key ? 1 : 0
  provider = oci.home

  compartment_id = var.tenancy_id
  name           = "${local.resource_name}-storage"
  description    = "Least-privilege Object Storage access for ${local.resource_name}"
}

resource "oci_identity_user_group_membership" "orthanc" {
  count    = var.create_storage_customer_secret_key ? 1 : 0
  provider = oci.home

  group_id = oci_identity_group.orthanc[0].id
  user_id  = local.storage_user_id

  lifecycle {
    precondition {
      condition     = length(local.storage_user_matches) == 1
      error_message = "storage_user_email must identify exactly one existing OCI IAM user in the tenancy."
    }

    precondition {
      condition = (
        length(local.storage_user_matches) != 1 ||
        local.storage_user_can_use_customer_secret_keys
      )
      error_message = "The OCI IAM user selected by storage_user_email cannot use Customer Secret Keys."
    }
  }
}

resource "oci_identity_policy" "orthanc_storage" {
  count    = var.create_storage_customer_secret_key ? 1 : 0
  provider = oci.home

  compartment_id = var.compartment_id
  name           = "${local.resource_name}-storage"
  description    = "Allow only the Orthanc service identity to access its DICOM image bucket"
  statements = [
    "Allow group ${oci_identity_group.orthanc[0].name} to read buckets in compartment id ${var.compartment_id} where target.bucket.name = '${local.bucket_name}'",
    "Allow group ${oci_identity_group.orthanc[0].name} to manage objects in compartment id ${var.compartment_id} where target.bucket.name = '${local.bucket_name}'",
  ]
  freeform_tags = local.tags
}

resource "oci_identity_customer_secret_key" "orthanc" {
  count    = var.create_storage_customer_secret_key ? 1 : 0
  provider = oci.home

  user_id      = local.storage_user_id
  display_name = "${local.resource_name}-orthanc-s3"

  depends_on = [
    oci_identity_user_group_membership.orthanc,
    oci_identity_policy.orthanc_storage,
  ]
}

resource "oci_identity_dynamic_group" "bastion" {
  provider = oci.home

  compartment_id = var.tenancy_id
  name           = "${local.resource_name}-oke-operators"
  description    = "Instance principal for the ${local.resource_name} OKE operator bastion"
  matching_rule  = "ALL {instance.id = '${oci_core_instance.bastion.id}'}"
  freeform_tags  = local.tags
}

resource "oci_identity_policy" "bastion_oke" {
  provider = oci.home

  compartment_id = var.compartment_id
  name           = "${local.resource_name}-bastion-oke"
  description    = "Allow the stack bastion to generate an instance-principal kubeconfig and operate its OKE cluster"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.bastion.name} to {CLUSTER_USE, CLUSTER_MANAGE} in compartment id ${var.compartment_id} where target.cluster.id = '${oci_containerengine_cluster.orthanc.id}'",
  ]
  freeform_tags = local.tags
}

resource "oci_identity_policy" "oke_network_load_balancer" {
  provider = oci.home

  compartment_id = var.compartment_id
  name           = "${local.resource_name}-oke-nlb"
  description    = "Allow this OKE cluster to provision its internal Network Load Balancer"
  statements = [
    "Allow any-user to manage load-balancers in compartment id ${var.compartment_id} where all {request.principal.type = 'cluster', request.principal.id = '${oci_containerengine_cluster.orthanc.id}'}",
    "Allow any-user to use virtual-network-family in compartment id ${var.compartment_id} where all {request.principal.type = 'cluster', request.principal.id = '${oci_containerengine_cluster.orthanc.id}'}",
  ]
  freeform_tags = local.tags
}
