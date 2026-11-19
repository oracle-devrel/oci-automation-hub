# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# IAM — Tenancy-level resources the stack needs:
#
#   * Data Flow: a dynamic group + policy so Data Flow runs (resource
#     principals) can read scripts and read/write logs & warehouse buckets in
#     this compartment.
#   * BDS: a policy granting the bdsprod service principal access to the
#     VCN/subnet so it can attach cluster nodes. Without it cluster creation
#     fails with "not enough permissions to access subnet or vcn details".
#
# Dynamic groups and policies live in the tenancy root, so the caller needs
# IAM admin rights on the tenancy. If that is not the case, set
# create_iam_resources = false and pre-create the resources out of band — see
# README.md for the exact matching rule and statements.
###############################################################################

locals {
  create_dataflow_iam = var.deploy_dataflow && var.create_iam_resources
  create_bds_iam      = var.deploy_bds && var.create_iam_resources
  create_operator_iam = var.deploy_operator && var.create_iam_resources
  create_iam          = local.create_dataflow_iam || local.create_bds_iam || local.create_operator_iam

  # Compartment that owns the network the BDS cluster attaches to. Defaults to
  # the deployment compartment (where create_vcn = true puts the VCN).
  bds_network_compartment = coalesce(var.bds_network_compartment_ocid, var.compartment_ocid)
}

resource "random_string" "iam_suffix" {
  count = local.create_iam ? 1 : 0

  length  = 6
  upper   = false
  special = false
}

resource "oci_identity_dynamic_group" "dataflow" {
  count    = local.create_dataflow_iam ? 1 : 0
  provider = oci.home

  compartment_id = var.tenancy_ocid
  name           = "${var.resource_prefix}-dataflow-dg-${random_string.iam_suffix[0].result}"
  description    = "Dynamic group containing Data Flow runs for ${var.resource_prefix}"
  matching_rule  = "ALL {resource.type='dataflowrun', resource.compartment.id='${var.compartment_ocid}'}"
  freeform_tags  = var.freeform_tags
}

resource "oci_identity_policy" "dataflow" {
  count    = local.create_dataflow_iam ? 1 : 0
  provider = oci.home

  compartment_id = var.tenancy_ocid
  name           = "${var.resource_prefix}-dataflow-policy-${random_string.iam_suffix[0].result}"
  description    = "Allow Data Flow runs to read/write the stack's Object Storage buckets."

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.dataflow[0].name} to read buckets in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.dataflow[0].name} to manage objects in compartment id ${var.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.dataflow[0].name} to read objectstorage-namespaces in tenancy",
  ]

  freeform_tags = var.freeform_tags
}

# Grants the Big Data Service (bdsprod) service principal the network access it
# needs to create VNICs and attach cluster nodes to the subnet. This must exist
# before the cluster is created, otherwise BDS reports "not enough permissions
# to access subnet or vcn details". The service name "bdsprod" is fixed by OCI.
resource "oci_identity_policy" "bds_network" {
  count    = local.create_bds_iam ? 1 : 0
  provider = oci.home

  compartment_id = local.bds_network_compartment
  name           = "${var.resource_prefix}-bds-network-policy-${random_string.iam_suffix[0].result}"
  description    = "Allow the BDS (bdsprod) service principal to attach clusters to the VCN/subnet."

  statements = [
    "Allow service bdsprod to {VNIC_READ, VNIC_ATTACH, VNIC_DETACH, VNIC_CREATE, VNIC_DELETE, VNIC_ATTACHMENT_READ, SUBNET_READ, VCN_READ, SUBNET_ATTACH, SUBNET_DETACH, INSTANCE_ATTACH_SECONDARY_VNIC, INSTANCE_DETACH_SECONDARY_VNIC} in compartment id ${local.bds_network_compartment}",
  ]

  freeform_tags = var.freeform_tags
}
