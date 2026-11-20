# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "oci_core_volume" "sql1_data" {
  availability_domain = local.selected_sql1_availability_domain
  compartment_id      = var.compartment_id
  display_name        = "SQL1-data"
  size_in_gbs         = var.sql_data_volume_size_in_gbs

  freeform_tags = merge(var.freeform_tags, {
    Role = "sql-data"
    Node = "SQL1"
  })
}

resource "oci_core_volume" "sql2_data" {
  availability_domain = local.selected_sql2_availability_domain
  compartment_id      = var.compartment_id
  display_name        = "SQL2-data"
  size_in_gbs         = var.sql_data_volume_size_in_gbs

  freeform_tags = merge(var.freeform_tags, {
    Role = "sql-data"
    Node = "SQL2"
  })
}

resource "oci_core_volume_attachment" "sql1_data" {
  attachment_type = "paravirtualized"
  display_name    = "SQL1-data-attachment"
  instance_id     = oci_core_instance.sql1.id
  volume_id       = oci_core_volume.sql1_data.id
}

resource "oci_core_volume_attachment" "sql2_data" {
  attachment_type = "paravirtualized"
  display_name    = "SQL2-data-attachment"
  instance_id     = oci_core_instance.sql2.id
  volume_id       = oci_core_volume.sql2_data.id
}
