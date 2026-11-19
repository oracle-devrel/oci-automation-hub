# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "tls_private_key" "generated_lb" {
  count = var.generate_lb_certificate ? 1 : 0

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "generated_lb" {
  count = var.generate_lb_certificate ? 1 : 0

  private_key_pem       = tls_private_key.generated_lb[0].private_key_pem
  validity_period_hours = 87600
  early_renewal_hours   = 720
  is_ca_certificate     = true

  subject {
    common_name  = var.certificate_common_name
    organization = "OCI FLB Benchmark"
  }

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

locals {
  lb_certificate_pem = var.generate_lb_certificate ? tls_self_signed_cert.generated_lb[0].cert_pem : var.lb_certificate_pem
  lb_private_key_pem = var.generate_lb_certificate ? tls_private_key.generated_lb[0].private_key_pem : var.lb_private_key_pem
  lb_ca_pem          = var.generate_lb_certificate ? tls_self_signed_cert.generated_lb[0].cert_pem : var.lb_ca_certificate_pem
}

resource "oci_load_balancer_load_balancer" "lb" {
  count = var.lb_count

  compartment_id             = var.compartment_ocid
  display_name               = "${local.safe_name_prefix}-flb-${count.index}"
  shape                      = "flexible"
  is_private                 = true
  subnet_ids                 = [oci_core_subnet.lb.id]
  network_security_group_ids = [oci_core_network_security_group.lb.id]

  shape_details {
    minimum_bandwidth_in_mbps = var.lb_min_mbps
    maximum_bandwidth_in_mbps = var.lb_max_mbps
  }

  lifecycle {
    precondition {
      condition     = var.lb_max_mbps >= var.lb_min_mbps
      error_message = "lb_max_mbps must be greater than or equal to lb_min_mbps."
    }
  }
}

resource "oci_load_balancer_certificate" "lb" {
  count = var.lb_count

  load_balancer_id   = oci_load_balancer_load_balancer.lb[count.index].id
  certificate_name   = "flb-simple-cert-${count.index}"
  public_certificate = local.lb_certificate_pem
  private_key        = local.lb_private_key_pem
  ca_certificate     = local.lb_ca_pem != "" ? local.lb_ca_pem : null

  lifecycle {
    precondition {
      condition     = var.generate_lb_certificate || (trimspace(var.lb_certificate_pem) != "" && trimspace(var.lb_private_key_pem) != "")
      error_message = "lb_certificate_pem and lb_private_key_pem must be non-empty when generate_lb_certificate is false."
    }
  }
}

resource "oci_load_balancer_backend_set" "backend_set" {
  count = var.lb_count

  load_balancer_id = oci_load_balancer_load_balancer.lb[count.index].id
  name             = "backendset1"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "HTTP"
    port              = 80
    url_path          = "/healthz"
    return_code       = 200
    retries           = 3
    interval_ms       = 10000
    timeout_in_millis = 5000
  }
}

resource "oci_load_balancer_backend" "backend" {
  count = var.lb_count * var.backend_count

  load_balancer_id = oci_load_balancer_load_balancer.lb[floor(count.index / var.backend_count)].id
  backendset_name  = oci_load_balancer_backend_set.backend_set[floor(count.index / var.backend_count)].name
  ip_address       = local.backend_private_ips[count.index % var.backend_count]
  port             = 80
  weight           = 1

  depends_on = [oci_core_instance.backend]
}

resource "oci_load_balancer_listener" "tcp_443_ssl" {
  count = var.lb_count

  load_balancer_id         = oci_load_balancer_load_balancer.lb[count.index].id
  name                     = "tcp-443-ssl"
  port                     = 443
  protocol                 = "TCP"
  default_backend_set_name = oci_load_balancer_backend_set.backend_set[count.index].name

  ssl_configuration {
    certificate_name        = oci_load_balancer_certificate.lb[count.index].certificate_name
    verify_peer_certificate = false
    protocols               = ["TLSv1.3", "TLSv1.2"]
    server_order_preference = "ENABLED"
    cipher_suite_name       = "oci-modern-ssl-cipher-suite-v1"
  }

  connection_configuration {
    idle_timeout_in_seconds = 1200
  }
}
