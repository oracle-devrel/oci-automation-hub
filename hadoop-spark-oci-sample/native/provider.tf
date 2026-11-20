# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.30.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }
}

# When the stack is launched from OCI Resource Manager, Resource Manager
# automatically injects tenancy_ocid, region, current_user_ocid, and the
# auth context. When running from the CLI the user supplies these via
# terraform.tfvars / environment variables / OCI config.
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# IAM (Identity) is a global service whose CREATE/UPDATE/DELETE operations are
# only accepted in the tenancy's home region. When the stack runs in any other
# region, identity writes against the local endpoint fail with:
#   403-NotAllowed, Please go to your home region <X> to execute CREATE...
# We discover the home region (a read, allowed from any region) and pin an
# aliased provider to it; every oci_identity_* resource uses provider = oci.home.
data "oci_identity_region_subscriptions" "this" {
  tenancy_id = var.tenancy_ocid
}

locals {
  home_region = one([
    for r in data.oci_identity_region_subscriptions.this.region_subscriptions :
    r.region_name if r.is_home_region
  ])
}

provider "oci" {
  alias            = "home"
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = local.home_region
}
