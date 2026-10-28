# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 8.16.0"
    }
  }
}

provider "oci" {
  region = var.region
}

locals {
  app_port                    = 8000
  certificate_pem             = file("${path.module}/modules/certificates/wildcard-app.crt")
  certificate_chain_pem       = file("${path.module}/modules/certificates/wildcard-ca.crt")
  certificate_private_key_pem = file("${path.module}/modules/certificates/wildcard-app.key")
  image_version               = length(regexall(":[^/]+$", var.app_image_url)) > 0 ? trimprefix(regexall(":[^/]+$", var.app_image_url)[0], ":") : "latest"
  effective_app_base_url      = "https://${module.app_load_balancer.public_ip}"
}

module "app_certificate" {
  source           = "./modules/certificate-import"
  compartment_id   = var.compartment_ocid
  certificate_name = "${var.app_name_prefix}-wc-cert"
  certificate_pem  = local.certificate_pem
  cert_chain_pem   = local.certificate_chain_pem
  private_key_pem  = local.certificate_private_key_pem
}

module "app_load_balancer" {
  source         = "./modules/load-balancer"
  compartment_id = var.compartment_ocid
  app_name       = "${var.app_name_prefix}-lb"
  subnet_id      = var.lb_subnet_id
  backend_port   = local.app_port
  certificate_id = module.app_certificate.certificate_id
  nsg_ids        = [oci_core_network_security_group.app["lb"].id]
  depends_on     = [oci_core_network_security_group_security_rule.app_ingress, oci_core_network_security_group_security_rule.app_egress]
}

module "identity_domain_app" {
  source               = "./modules/identity-domain-app"
  identity_domain_ocid = var.identity_domain_ocid
  app_base_url         = local.effective_app_base_url
  app_name             = "${var.app_name_prefix}-app"
}

module "test_container_instance" {
  source                 = "./modules/container-instance"
  ocpus                  = var.ocpus
  memory_in_gbs          = var.memory_in_gbs
  shape                  = var.shape
  compartment_id         = var.compartment_ocid
  availability_domain    = var.availability_domain
  subnet_id              = var.app_subnet_id
  app_name               = "${var.app_name_prefix}-app-server"
  image_url              = var.app_image_url
  image_version          = local.image_version
  app_base_url           = local.effective_app_base_url
  identity_domain_issuer = module.identity_domain_app.identity_domain_issuer
  oidc_client_id         = module.identity_domain_app.client_id
  oidc_client_secret     = module.identity_domain_app.client_secret
  assign_public_ip       = var.assign_public_ip
  nsg_ids                = [oci_core_network_security_group.app["ui"].id]
  depends_on             = [oci_core_network_security_group_security_rule.app_ingress, oci_core_network_security_group_security_rule.app_egress]
}

module "app_load_balancer_backend" {
  source             = "./modules/load-balancer-backend"
  load_balancer_id   = module.app_load_balancer.load_balancer_id
  backendset_name    = module.app_load_balancer.backend_set_name
  backend_ip_address = module.test_container_instance.private_ip
  backend_port       = local.app_port
}

module "mcp_server" {
  source                          = "./modules/mcp-ci"
  tenancy_ocid                    = var.tenancy_ocid
  region                          = var.region
  compartment_id                  = var.compartment_ocid
  availability_domain             = var.availability_domain
  container_instance_display_name = "${var.app_name_prefix}-mcp-server-instance"
  container_image_url             = var.mcp_container_image_url
  container_display_name          = "${var.app_name_prefix}mcp-server-container"
  rag_agent_endpoint_id           = var.rag_agent_endpoint_id
  shape                           = var.shape
  ocpus                           = var.ocpus
  memory_in_gbs                   = var.memory_in_gbs
  subnet_id                       = var.app_subnet_id
  assign_public_ip                = var.assign_public_ip
  nsg_ids                         = [oci_core_network_security_group.app["mcp"].id]
  depends_on                      = [oci_core_network_security_group_security_rule.app_ingress, oci_core_network_security_group_security_rule.app_egress]
}