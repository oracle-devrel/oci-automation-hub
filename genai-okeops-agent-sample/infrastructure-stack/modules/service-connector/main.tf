# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "oci_sch_service_connector" "this" {
  compartment_id = var.compartment_ocid
  display_name   = var.display_name
  description    = var.description


  source {
        #Required
        kind = "logging"
        log_sources {

            #Optional
            compartment_id = var.compartment_ocid
            log_group_id = var.source_log_group_id
            log_id = var.log_id
        }
    }
  target {
    kind      = "streaming"
    stream_id = var.target_stream_id
  }
}



