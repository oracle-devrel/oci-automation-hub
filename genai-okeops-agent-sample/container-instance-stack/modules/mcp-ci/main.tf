# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
locals {
  health_checks = [{
    health_check_type        = "HTTP"
    path                     = "/healthz"
    port                     = 8080
    failure_action           = "KILL"
    initial_delay_in_seconds = 10
    interval_in_seconds      = 30
    timeout_in_seconds       = 5
    success_threshold        = 1
    failure_threshold        = 3
  }]
}

resource "oci_container_instances_container_instance" "this" {
  compartment_id      = var.compartment_id
  availability_domain = var.availability_domain
  display_name        = var.container_instance_display_name
  shape               = var.shape

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  containers {
    display_name = var.container_display_name
    image_url    = var.container_image_url
    environment_variables = {
      OCI_TENANCY_ID    = var.tenancy_ocid
      AGENT_ENDPOINT_ID = var.rag_agent_endpoint_id != null ? var.rag_agent_endpoint_id : "NONE"
      LOG_LEVEL         = "DEBUG"
    }

    dynamic "health_checks" {
      for_each = local.health_checks
      content {
        health_check_type        = health_checks.value.health_check_type
        path                     = health_checks.value.path
        port                     = health_checks.value.port
        failure_action           = health_checks.value.failure_action
        initial_delay_in_seconds = health_checks.value.initial_delay_in_seconds
        interval_in_seconds      = health_checks.value.interval_in_seconds
        timeout_in_seconds       = health_checks.value.timeout_in_seconds
        success_threshold        = health_checks.value.success_threshold
        failure_threshold        = health_checks.value.failure_threshold
      }
    }
  }

  vnics {
    nsg_ids               = var.nsg_ids
    subnet_id             = var.subnet_id
    is_public_ip_assigned = var.assign_public_ip
  }
}
