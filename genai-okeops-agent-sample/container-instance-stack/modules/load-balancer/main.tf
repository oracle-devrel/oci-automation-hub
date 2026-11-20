# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

resource "oci_load_balancer_load_balancer" "this" {
  compartment_id             = var.compartment_id
  display_name               = var.app_name
  shape                      = "flexible"
  subnet_ids                 = [var.subnet_id]
  is_private                 = false
  network_security_group_ids = var.nsg_ids
  freeform_tags = {
    app       = var.app_name
    component = "load-balancer"
  }

  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 10
  }
}

resource "oci_load_balancer_backend_set" "this" {
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  name             = "${var.app_name}-backend-set"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "HTTP"
    port              = var.backend_port
    url_path          = "/healthz"
    return_code       = 200
    retries           = 3
    timeout_in_millis = 5000
    interval_ms       = 30000
  }
}

resource "oci_load_balancer_listener" "https" {
  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "${var.app_name}-https"
  default_backend_set_name = oci_load_balancer_backend_set.this.name
  port                     = 443
  protocol                 = "HTTP"

  ssl_configuration {
    certificate_ids         = [var.certificate_id]
    verify_peer_certificate = false
  }
}
