resource "oci_core_network_security_group" "this" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.name_prefix}-load-balancer-nsg"

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}

resource "oci_core_network_security_group_security_rule" "https_ingress" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow HTTPS traffic to the public load balancer."

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "https_egress" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow HTTPS traffic from the load balancer to OIC."

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_load_balancer_load_balancer" "this" {
  compartment_id             = var.compartment_id
  display_name               = "${var.name_prefix}-load-balancer"
  shape                      = "flexible"
  subnet_ids                 = [var.subnet_id]
  is_private                 = false
  network_security_group_ids = [oci_core_network_security_group.this.id]

  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 10
  }

  defined_tags  = var.defined_tags
  freeform_tags = var.freeform_tags
}

# Keep the OIC leaf certificate and CA chain as a load-balancer-managed
# certificate: the OIC private key is neither available nor required for
# backend TLS.
resource "oci_load_balancer_certificate" "oic_backend" {
  load_balancer_id   = oci_load_balancer_load_balancer.this.id
  certificate_name   = "oic-backend"
  public_certificate = var.backend_server_certificate_pem
  ca_certificate     = var.backend_ca_certificate_pem
}

resource "oci_load_balancer_backend_set" "oic" {
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  name             = "oic-backend-set"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol = "TCP"
    port     = 443
    retries  = 3
  }

  # Encrypt connections from the load balancer to OIC. Peer-certificate
  # validation is disabled because the OIC backend certificate is managed
  # independently by Oracle.
  ssl_configuration {
    certificate_name        = oci_load_balancer_certificate.oic_backend.certificate_name
    verify_peer_certificate = false
  }
}

resource "oci_load_balancer_backend" "oic" {
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  backendset_name  = oci_load_balancer_backend_set.oic.name
  ip_address       = var.backend_ip_address
  port             = 443
}

resource "oci_load_balancer_listener" "https" {
  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "https"
  default_backend_set_name = oci_load_balancer_backend_set.oic.name
  port                     = 443
  protocol                 = "TCP"

  ssl_configuration {
    certificate_ids         = [var.listener_certificate_id]
    verify_peer_certificate = false
  }
}
