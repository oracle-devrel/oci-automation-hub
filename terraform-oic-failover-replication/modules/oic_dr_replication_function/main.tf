locals {
  application_name      = substr("${var.name_prefix}-oic-dr-functions", 0, 255)
  function_name         = substr("${var.name_prefix}-oic-dr-replication", 0, 255)
  schedule_name         = substr("${var.name_prefix}-oic-dr-hourly", 0, 255)
  scheduler_dg_name     = substr("${var.name_prefix}-oic-dr-scheduler", 0, 100)
  scheduler_policy_name = substr("${var.name_prefix}-oic-dr-scheduler-policy", 0, 100)
  function_dg_name      = substr("${var.name_prefix}-oic-dr-function", 0, 100)
  function_policy_name  = substr("${var.name_prefix}-oic-dr-function-policy", 0, 100)
  archive_bucket_name   = "oic-dr"
  function_image        = "${var.secondary_region}.ocir.io/${data.oci_objectstorage_namespace.this.namespace}/oic-dr-replication:1.0.0"
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_id
}

resource "oci_objectstorage_bucket" "archives" {
  compartment_id = var.compartment_id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = local.archive_bucket_name
  access_type    = "NoPublicAccess"
  freeform_tags  = var.freeform_tags
}

resource "oci_functions_application" "this" {
  compartment_id = var.compartment_id
  display_name   = local.application_name
  subnet_ids     = [var.subnet_id]
  freeform_tags  = var.freeform_tags
}

# Tokens are requested by the handler on every invocation. The Function never
# receives the short-lived bearer-token values produced during terraform apply.
resource "oci_functions_function" "this" {
  application_id                   = oci_functions_application.this.id
  display_name                     = local.function_name
  image                            = local.function_image
  memory_in_mbs                    = tostring(var.function_memory_in_mbs)
  timeout_in_seconds               = var.function_timeout_in_seconds
  detached_mode_timeout_in_seconds = var.function_timeout_in_seconds
  freeform_tags                    = var.freeform_tags

  config = {
    PRIMARY_OIC_URL          = trimsuffix(var.primary_oic_url, "/")
    SECONDARY_OIC_URL        = trimsuffix(var.secondary_oic_url, "/")
    IDCS_ENDPOINT            = trimsuffix(var.idcs_endpoint, "/")
    PRIMARY_CLIENT_ID        = var.primary_client_id
    PRIMARY_CLIENT_SECRET    = var.primary_client_secret
    PRIMARY_SCOPE            = join(" ", var.primary_scope_fqs)
    SECONDARY_CLIENT_ID      = var.secondary_client_id
    SECONDARY_CLIENT_SECRET  = var.secondary_client_secret
    SECONDARY_SCOPE          = join(" ", var.secondary_scope_fqs)
    OBJECT_STORAGE_NAMESPACE = data.oci_objectstorage_namespace.this.namespace
    OBJECT_STORAGE_BUCKET    = oci_objectstorage_bucket.archives.name
  }

  lifecycle {
    # These root-module references preserve ordering for the Function without
    # delaying unrelated module resources such as the archive bucket.
    precondition {
      condition     = length(var.role_grant_ids) == 2
      error_message = "Expected the primary and secondary OIC ServiceAdministrator grants before creating the replication Function."
    }
  }
}

# The Function uses its resource principal to store each primary export and
# retrieve that exact object before importing it into the secondary instance.
resource "oci_identity_dynamic_group" "function" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = local.function_dg_name
  description    = "Allows the OIC DR replication Function to store integration archives."
  matching_rule  = "ALL {resource.type = 'fnfunc', resource.id = '${oci_functions_function.this.id}'}"
}

resource "oci_identity_policy" "function" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = local.function_policy_name
  description    = "Allows the OIC DR replication Function to manage its Object Storage archives."
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.function.name} to manage objects in compartment id ${var.compartment_id}",
  ]
}

# Resource Scheduler uses standard five-field cron syntax. This expression runs
# at minute zero of every hour in UTC.
resource "oci_resource_scheduler_schedule" "this" {
  compartment_id     = var.compartment_id
  display_name       = local.schedule_name
  description        = "Hourly replication of OIC integration versions from primary to secondary."
  action             = "START_RESOURCE"
  recurrence_type    = "CRON"
  recurrence_details = "0 * * * *"
  time_starts        = var.schedule_start_time
  freeform_tags      = var.freeform_tags

  resources {
    id = oci_functions_function.this.id
  }
}

# Resource Scheduler requires its own dynamic group to invoke Functions.
resource "oci_identity_dynamic_group" "scheduler" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = local.scheduler_dg_name
  description    = "Allows the ${local.schedule_name} resource schedule to invoke its OIC DR Function."
  matching_rule  = "ALL {resource.type = 'resourceschedule', resource.id = '${oci_resource_scheduler_schedule.this.id}'}"
}

resource "oci_identity_policy" "scheduler" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = local.scheduler_policy_name
  description    = "Allows the OIC DR resource schedule to invoke OCI Functions."
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.scheduler.name} to manage functions-family in tenancy",
  ]
}
