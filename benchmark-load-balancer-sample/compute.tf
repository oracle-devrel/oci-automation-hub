# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_core_instance" "backend" {
  count = var.backend_count

  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${local.safe_name_prefix}-backend-${count.index}"
  shape               = var.backend_shape

  dynamic "shape_config" {
    for_each = length(regexall("\\.Flex$", var.backend_shape)) > 0 ? [1] : []
    content {
      ocpus         = var.backend_ocpus
      memory_in_gbs = var.backend_memory_gb
    }
  }

  source_details {
    source_type = "image"
    source_id   = var.image_ocid
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.backend.id
    assign_public_ip = false
    private_ip       = local.backend_private_ips[count.index]
    nsg_ids          = [oci_core_network_security_group.backend.id]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloud-init/backend.sh.tftpl", {
      payload_sizes_json = jsonencode(var.payload_sizes)
    }))
  }

  depends_on = [
    oci_core_network_security_group_security_rule.backend_ingress_80_from_lb,
    oci_core_network_security_group_security_rule.backend_egress_all,
  ]
}

resource "oci_core_instance" "generator" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${local.safe_name_prefix}-generator"
  shape               = var.generator_shape

  dynamic "shape_config" {
    for_each = length(regexall("\\.Flex$", var.generator_shape)) > 0 ? [1] : []
    content {
      ocpus         = var.generator_ocpus
      memory_in_gbs = var.generator_memory_gb
    }
  }

  source_details {
    source_type = "image"
    source_id   = var.image_ocid
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.generator.id
    assign_public_ip = true
    private_ip       = local.generator_private_ip
    nsg_ids          = [oci_core_network_security_group.generator.id]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloud-init/generator.sh.tftpl", {
      config_json_b64gz   = base64gzip(jsonencode(local.benchmark_config))
      controller_py_b64gz = base64gzip(file("${path.module}/scripts/controller.py"))
      locustfile_py_b64gz = base64gzip(file("${path.module}/scripts/locustfile.py"))
    }))
  }

  depends_on = [
    oci_core_network_security_group_security_rule.generator_egress_all,
    oci_core_network_security_group_security_rule.generator_egress_443_to_lbs,
    oci_core_network_security_group_security_rule.generator_ingress_ephemeral_from_lbs,
    oci_core_network_security_group_security_rule.lb_ingress_443_from_generator,
    oci_core_network_security_group_security_rule.lb_egress_ephemeral_to_generator,
    oci_core_network_security_group_security_rule.lb_egress_80_to_backends,
    oci_core_network_security_group_security_rule.lb_ingress_ephemeral_from_backends,
    oci_core_network_security_group_security_rule.backend_egress_ephemeral_to_lbs,
    oci_load_balancer_backend.backend,
    oci_load_balancer_listener.tcp_443_ssl,
  ]

  lifecycle {
    precondition {
      condition     = contains(keys(var.payload_sizes), var.throughput_payload_key)
      error_message = "throughput_payload_key must exist in payload_sizes."
    }

    precondition {
      condition     = var.max_workers >= var.min_workers
      error_message = "max_workers must be greater than or equal to min_workers."
    }

    precondition {
      condition     = can(cidrhost(var.backend_subnet_cidr, var.backend_count + 9))
      error_message = "backend_subnet_cidr must have enough usable addresses for backend_count plus reserved offsets."
    }

    precondition {
      condition     = can(cidrhost(var.generator_subnet_cidr, 10))
      error_message = "generator_subnet_cidr must have enough addresses for the static generator IP offset."
    }

    precondition {
      condition = length(distinct([
        var.lb_subnet_cidr,
        var.backend_subnet_cidr,
        var.generator_subnet_cidr,
      ])) == 3
      error_message = "lb_subnet_cidr, backend_subnet_cidr, and generator_subnet_cidr must be distinct."
    }
  }
}
