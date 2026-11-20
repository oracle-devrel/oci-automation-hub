# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_psql_db_system" "orthanc" {
  compartment_id = var.compartment_id
  display_name   = "${local.resource_name}-postgres"
  description    = "Highly available managed PostgreSQL metadata index for ${local.resource_name}"
  db_version     = var.postgres_version
  shape          = var.postgres_shape

  instance_count              = var.postgres_instances
  instance_ocpu_count         = var.postgres_ocpus
  instance_memory_size_in_gbs = var.postgres_memory_gb

  credentials {
    username = var.postgres_admin_username

    password_details {
      password_type = "PLAIN_TEXT"
      password      = local.postgres_password
    }
  }

  network_details {
    subnet_id = oci_core_subnet.database.id
    nsg_ids   = [local.postgres_nsg.id]
  }

  storage_details {
    is_regionally_durable = true
    system_type           = "OCI_OPTIMIZED_STORAGE"
  }

  management_policy {
    backup_policy {
      kind           = "DAILY"
      backup_start   = var.postgres_backup_start
      retention_days = var.postgres_backup_retention_days
    }
    maintenance_window_start = var.postgres_maintenance_window_start
  }

  freeform_tags = local.tags

  timeouts {
    create = "120m"
    update = "120m"
    delete = "120m"
  }
}
