# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_core_public_ip" "large_upload" {
  count          = var.enable_large_upload_endpoint ? 1 : 0
  compartment_id = var.compartment_id
  display_name   = "${local.resource_name}-large-upload"
  lifetime       = "RESERVED"
  freeform_tags  = local.tags

  lifecycle {
    # The Kubernetes service controller attaches this address to the NLB.
    ignore_changes = [private_ip_id]
  }
}

resource "tls_private_key" "large_upload" {
  count     = var.enable_large_upload_endpoint ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 3072
}

resource "tls_self_signed_cert" "large_upload" {
  count                 = var.enable_large_upload_endpoint ? 1 : 0
  private_key_pem       = tls_private_key.large_upload[0].private_key_pem
  validity_period_hours = 8760
  early_renewal_hours   = 720
  ip_addresses          = [oci_core_public_ip.large_upload[0].ip_address]
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
  subject {
    common_name = "${local.resource_name}-large-upload"
  }
}

resource "oci_core_network_security_group" "large_upload" {
  count          = var.enable_large_upload_endpoint ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.dicom.id
  display_name   = "${local.resource_name}-large-upload"
  freeform_tags  = local.tags
}

resource "oci_core_network_security_group_security_rule" "large_upload_clients" {
  for_each                  = var.enable_large_upload_endpoint ? toset(var.allowed_client_cidrs) : toset([])
  network_security_group_id = oci_core_network_security_group.large_upload[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  description               = "Approved large-upload HTTPS clients"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "large_upload_to_nodes" {
  for_each                  = var.enable_large_upload_endpoint ? toset(["31443", "10256"]) : toset([])
  network_security_group_id = oci_core_network_security_group.large_upload[0].id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = local.oke_nodes_nsg.id
  tcp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_from_large_upload" {
  for_each                  = var.enable_large_upload_endpoint ? toset(["31443", "10256"]) : toset([])
  network_security_group_id = local.oke_nodes_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.large_upload[0].id
  tcp_options {
    destination_port_range {
      min = tonumber(each.value)
      max = tonumber(each.value)
    }
  }
}

output "large_upload_endpoint" {
  description = "HTTPS Orthanc upload root bypassing API Gateway; clients must trust large_upload_certificate."
  value       = var.enable_large_upload_endpoint ? "https://${oci_core_public_ip.large_upload[0].ip_address}/orthanc" : null
}

output "large_upload_dicomweb_endpoint" {
  description = "DICOMweb endpoint for large STOW-RS uploads."
  value       = var.enable_large_upload_endpoint ? "https://${oci_core_public_ip.large_upload[0].ip_address}/orthanc/dicom-web" : null
}

output "large_upload_certificate" {
  description = "Public certificate to pin with curl --cacert or the client trust store. Redistribute after renewal."
  value       = var.enable_large_upload_endpoint ? tls_self_signed_cert.large_upload[0].cert_pem : null
}
