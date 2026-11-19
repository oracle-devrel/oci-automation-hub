# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# OCI Data Flow — managed Spark applications + optional warm pool
###############################################################################

# Optional warm pool: keeps a small set of executors hot so Data Flow runs
# start in seconds instead of ~1 minute. Apps reference it via pool_id.
resource "oci_dataflow_pool" "this" {
  count = var.deploy_dataflow && var.dataflow_create_pool ? 1 : 0

  compartment_id = var.compartment_ocid
  display_name   = "${var.resource_prefix}-dataflow-pool"

  configurations {
    shape = var.dataflow_pool_shape
    min   = var.dataflow_pool_min_executors
    max   = var.dataflow_pool_max_executors

    shape_config {
      ocpus         = var.dataflow_pool_ocpus
      memory_in_gbs = var.dataflow_pool_memory_gbs
    }
  }

  freeform_tags = var.freeform_tags
}

locals {
  # Resolve the effective file_uri for each application. If the user did not
  # supply one, fall back to the sample script we uploaded for that language.
  dataflow_apps = var.deploy_dataflow ? {
    for app in var.dataflow_applications :
    app.name => merge(app, {
      resolved_file_uri = (
        length(app.file_uri) > 0
        ? app.file_uri
        : (
          contains(keys(local.sample_scripts), app.language) && var.dataflow_create_scripts_bucket && var.dataflow_upload_sample_scripts
          ? "${local.scripts_bucket_uri}${local.sample_scripts[app.language].filename}"
          : ""
        )
      )
    })
  } : {}
}

resource "oci_dataflow_application" "this" {
  for_each = local.dataflow_apps

  compartment_id = var.compartment_ocid
  display_name   = "${var.resource_prefix}-${each.value.name}"
  description    = "Showcase Spark application: ${each.value.name}"

  language      = each.value.language
  spark_version = each.value.spark_version
  file_uri      = each.value.resolved_file_uri
  class_name    = each.value.class_name
  arguments     = each.value.arguments

  driver_shape   = each.value.driver_shape
  executor_shape = each.value.executor_shape
  num_executors  = each.value.num_executors

  dynamic "driver_shape_config" {
    for_each = can(regex("Flex$", each.value.driver_shape)) ? [1] : []
    content {
      ocpus         = each.value.driver_ocpus
      memory_in_gbs = each.value.driver_memory_gbs
    }
  }

  dynamic "executor_shape_config" {
    for_each = can(regex("Flex$", each.value.executor_shape)) ? [1] : []
    content {
      ocpus         = each.value.executor_ocpus
      memory_in_gbs = each.value.executor_memory_gbs
    }
  }

  configuration = each.value.configuration

  logs_bucket_uri      = local.logs_bucket_uri
  warehouse_bucket_uri = local.warehouse_bucket_uri

  pool_id = var.dataflow_create_pool ? oci_dataflow_pool.this[0].id : null

  type          = "BATCH"
  freeform_tags = var.freeform_tags

  lifecycle {
    precondition {
      condition     = length(each.value.resolved_file_uri) > 0
      error_message = "Application '${each.value.name}' has no file_uri and no bundled sample is available for language ${each.value.language}. Either set file_uri or enable dataflow_upload_sample_scripts."
    }

    precondition {
      condition     = !contains(["JAVA", "SCALA"], each.value.language) || length(each.value.class_name) > 0
      error_message = "Application '${each.value.name}' uses ${each.value.language} but class_name is empty."
    }
  }

  depends_on = [
    oci_objectstorage_object.sample_scripts,
    oci_identity_policy.dataflow,
  ]
}
