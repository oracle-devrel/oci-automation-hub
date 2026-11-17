# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.24"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "oci" {
  region              = var.region
  config_file_profile = var.oci_profile
  auth                = var.oci_auth
}

provider "oci" {
  alias               = "home"
  region              = var.home_region
  config_file_profile = var.oci_profile
  auth                = var.oci_auth
}
