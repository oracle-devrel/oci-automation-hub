# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

provider "oci" {
  alias                = "home"
  region               = lookup(data.oci_identity_regions.home_region.regions[0], "name")
  tenancy_ocid         = var.tenancy_ocid
  config_file_profile  = var.oci_auth_mode == "profile" ? var.oci_config_profile : null
  user_ocid            = var.oci_auth_mode == "explicit" ? var.oci_user_ocid : null
  fingerprint          = var.oci_auth_mode == "explicit" ? var.oci_fingerprint : null
  private_key_path     = var.oci_auth_mode == "explicit" ? var.oci_private_key_path : null
  private_key_password = var.oci_private_key_password
}

provider "oci" {
  region               = var.region
  tenancy_ocid         = var.tenancy_ocid
  config_file_profile  = var.oci_auth_mode == "profile" ? var.oci_config_profile : null
  user_ocid            = var.oci_auth_mode == "explicit" ? var.oci_user_ocid : null
  fingerprint          = var.oci_auth_mode == "explicit" ? var.oci_fingerprint : null
  private_key_path     = var.oci_auth_mode == "explicit" ? var.oci_private_key_path : null
  private_key_password = var.oci_private_key_password
}

terraform {
  required_version = ">= 1.3.0"

  required_providers {

    oci = {
      configuration_aliases = [oci.home]
      source                = "oracle/oci"
      version               = ">= 4.119.0"
    }
  }
}
