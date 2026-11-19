# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  compartment_layout = {
    network = {
      suffix      = "network"
      description = "Networking resources for the FSTech Drive-Thru application"
    }
    data = {
      suffix      = "data"
      description = "Database resources and persistent data for FSTech Drive-Thru"
    }
    ai = {
      suffix      = "ai"
      description = "Generative AI Agent resources for FSTech Drive-Thru"
    }
    application = {
      suffix      = "application"
      description = "Application runtime, speech jobs, and object storage for FSTech Drive-Thru"
    }
  }
}

resource "oci_identity_compartment" "application_layers" {
  for_each = local.compartment_layout
  provider = oci.home

  compartment_id = var.compartment_ocid
  name           = "${var.name_prefix}-${each.value.suffix}"
  description    = each.value.description
  enable_delete  = true
  freeform_tags  = var.freeform_tags
}
