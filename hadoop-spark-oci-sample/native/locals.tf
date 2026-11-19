# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_ocid
}

locals {
  ad_name = data.oci_identity_availability_domains.ads.availability_domains[0].name

  os_namespace = data.oci_objectstorage_namespace.ns.namespace

  vcn_id            = var.create_vcn ? oci_core_vcn.this[0].id : var.existing_vcn_id
  private_subnet_id = var.create_vcn ? oci_core_subnet.private[0].id : var.existing_private_subnet_id
  public_subnet_id = (
    var.create_vcn
    ? oci_core_subnet.public[0].id
    : var.existing_public_subnet_id
  )

  bds_display_name      = coalesce(var.bds_display_name, "${var.resource_prefix}-hadoop")
  logs_bucket_name      = "${var.resource_prefix}-dataflow-logs"
  warehouse_bucket_name = "${var.resource_prefix}-dataflow-warehouse"
  scripts_bucket_name   = "${var.resource_prefix}-dataflow-scripts"

  # Sample scripts shipped with the stack, keyed by language. When a user
  # does not provide a file_uri for an application we fall back to one of
  # these. The path is relative to the module root and is uploaded into the
  # scripts bucket when dataflow_upload_sample_scripts = true.
  sample_scripts = {
    PYTHON = {
      filename = "pi.py"
      source   = "${path.module}/examples/pi.py"
    }
    SQL = {
      filename = "demo.sql"
      source   = "${path.module}/examples/demo.sql"
    }
  }

  scripts_bucket_uri = (
    var.deploy_dataflow && var.dataflow_create_scripts_bucket
    ? "oci://${local.scripts_bucket_name}@${local.os_namespace}/"
    : ""
  )

  logs_bucket_uri = (
    var.deploy_dataflow && var.dataflow_create_logs_bucket
    ? "oci://${local.logs_bucket_name}@${local.os_namespace}/"
    : ""
  )

  warehouse_bucket_uri = (
    var.deploy_dataflow && var.dataflow_create_warehouse_bucket
    ? "oci://${local.warehouse_bucket_name}@${local.os_namespace}/"
    : ""
  )
}
