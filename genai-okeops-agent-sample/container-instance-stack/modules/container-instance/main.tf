# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
locals {
  app_data_dir       = "/app/data"
  app_port           = 8000
  auth_cookie_secure = startswith(lower(var.app_base_url), "https://") ? "true" : "false"

  app_environment_variables = {
    PORT                       = tostring(local.app_port)
    LOG_LEVEL                  = "DEBUG"
    APP_BASE_URL               = trimsuffix(var.app_base_url, "/")
    APP_DATA_DIR               = local.app_data_dir
    AUTH_ENABLED               = "true"
    AUTH_COOKIE_SECURE         = local.auth_cookie_secure
    OCI_GENAI_AUTH_MODE        = "RESOURCE_PRINCIPAL"
    OCI_IDENTITY_DOMAIN_ISSUER = trimsuffix(var.identity_domain_issuer, "/")
    OCI_OIDC_CLIENT_ID         = var.oidc_client_id
    OCI_OIDC_CLIENT_SECRET     = var.oidc_client_secret
  }
}

resource "oci_container_instances_container_instance" "app" {
  availability_domain      = var.availability_domain
  compartment_id           = var.compartment_id
  container_restart_policy = "ALWAYS"
  display_name             = var.app_name
  shape                    = var.shape
  freeform_tags = {
    app         = var.app_name
    image       = var.app_name
    image_tag   = var.image_version
    environment = "test"
  }

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  containers {
    display_name                   = var.app_name
    image_url                      = var.image_url
    environment_variables          = local.app_environment_variables
    is_resource_principal_disabled = false
  }

  vnics {
    nsg_ids                = var.nsg_ids
    display_name           = "${var.app_name}-vnic"
    subnet_id              = var.subnet_id
    is_public_ip_assigned  = var.assign_public_ip
    skip_source_dest_check = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "oci_core_vnic" "app" {
  vnic_id = oci_container_instances_container_instance.app.vnics[0].vnic_id
}
