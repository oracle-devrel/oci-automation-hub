# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  adb_db_name = upper(substr("${var.name_prefix}${random_string.deployment.result}DB", 0, 30))
}

resource "random_string" "deployment" {
  length  = 6
  upper   = false
  special = false
}

resource "random_password" "adb_admin" {
  length      = 28
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

resource "random_password" "adb_wallet" {
  length      = 28
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

resource "oci_database_autonomous_database" "app" {
  compartment_id                      = oci_identity_compartment.application_layers["data"].id
  db_name                             = local.adb_db_name
  display_name                        = "${var.name_prefix}-drive-thru-adb-${random_string.deployment.result}"
  db_workload                         = "OLTP"
  db_version                          = "26ai"
  admin_password                      = random_password.adb_admin.result
  compute_model                       = "ECPU"
  compute_count                       = var.adb_compute_count
  data_storage_size_in_tbs            = 1
  is_auto_scaling_enabled             = true
  is_auto_scaling_for_storage_enabled = true
  is_mtls_connection_required         = true
  license_model                       = "LICENSE_INCLUDED"
  freeform_tags                       = var.freeform_tags
}

resource "oci_database_autonomous_database_wallet" "app" {
  autonomous_database_id = oci_database_autonomous_database.app.id
  password               = random_password.adb_wallet.result
  generate_type          = "SINGLE"
  base64_encode_content  = true
}
