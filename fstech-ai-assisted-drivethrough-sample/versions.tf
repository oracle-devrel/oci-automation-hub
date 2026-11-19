# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

terraform {
  # OCI Resource Manager currently runs Terraform 1.5.x (CLI 1.5.7).
  required_version = ">= 1.5.0, < 1.6.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 7.26.0, < 9.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  region       = var.region
  auth         = var.provider_auth == "" ? null : var.provider_auth
}

# IAM mutations must be sent to the tenancy home-region endpoint. The home
# region is discovered from the tenancy's region subscriptions, so users do
# not enter or map region keys manually.
provider "oci" {
  alias        = "home"
  tenancy_ocid = var.tenancy_ocid
  region       = local.home_region
  auth         = var.provider_auth == "" ? null : var.provider_auth
}
