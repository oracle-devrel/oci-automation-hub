# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

resource "oci_load_balancer_backend" "this" {
  load_balancer_id = var.load_balancer_id
  backendset_name  = var.backendset_name
  ip_address       = var.backend_ip_address
  port             = var.backend_port
}
