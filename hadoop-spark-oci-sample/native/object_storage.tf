# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

###############################################################################
# Object Storage buckets for Data Flow
###############################################################################

resource "oci_objectstorage_bucket" "logs" {
  count = var.deploy_dataflow && var.dataflow_create_logs_bucket ? 1 : 0

  compartment_id = var.compartment_ocid
  namespace      = local.os_namespace
  name           = local.logs_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  freeform_tags  = var.freeform_tags
}

resource "oci_objectstorage_bucket" "warehouse" {
  count = var.deploy_dataflow && var.dataflow_create_warehouse_bucket ? 1 : 0

  compartment_id = var.compartment_ocid
  namespace      = local.os_namespace
  name           = local.warehouse_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  freeform_tags  = var.freeform_tags
}

resource "oci_objectstorage_bucket" "scripts" {
  count = var.deploy_dataflow && var.dataflow_create_scripts_bucket ? 1 : 0

  compartment_id = var.compartment_ocid
  namespace      = local.os_namespace
  name           = local.scripts_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  freeform_tags  = var.freeform_tags
}

# Upload bundled sample scripts so the default Data Flow application has
# something to execute out of the box.
resource "oci_objectstorage_object" "sample_scripts" {
  for_each = (
    var.deploy_dataflow
    && var.dataflow_create_scripts_bucket
    && var.dataflow_upload_sample_scripts
  ) ? local.sample_scripts : {}

  namespace = local.os_namespace
  bucket    = oci_objectstorage_bucket.scripts[0].name
  object    = each.value.filename
  source    = each.value.source
}

# Stage the use-case assets so the operator VM can pull them onto itself with
# instance-principal auth at boot. Only uploaded when an operator is deployed
# and a scripts bucket exists to hold them.
locals {
  operator_assets = (
    var.deploy_operator && var.deploy_dataflow && var.dataflow_create_scripts_bucket
  ) ? fileset("${path.module}/use-cases", "**") : toset([])
}

resource "oci_objectstorage_object" "operator_assets" {
  for_each = local.operator_assets

  namespace = local.os_namespace
  bucket    = oci_objectstorage_bucket.scripts[0].name
  object    = "use-cases/${each.value}"
  source    = "${path.module}/use-cases/${each.value}"
}
