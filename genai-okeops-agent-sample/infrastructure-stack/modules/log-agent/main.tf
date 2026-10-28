# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "oci_logging_unified_agent_configuration" "this" {
  compartment_id = var.compartment_ocid
  description    = var.description
  display_name   = var.display_name
  is_enabled     = var.is_enabled
  defined_tags   = var.defined_tags
  freeform_tags  = var.freeform_tags

  group_association {
    group_list = var.group_list
  }

  service_configuration {
    configuration_type = "LOGGING"

    destination {
      log_object_id = var.log_object_id
    }

    sources {
      name        = var.source_name
      source_type = "LOG_TAIL"
      paths       = var.paths

      parser {
        parser_type = var.parser_type
        message_key = var.message_key
      }
    }
  }
}