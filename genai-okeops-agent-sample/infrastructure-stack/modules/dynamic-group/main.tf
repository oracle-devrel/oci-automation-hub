# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
provider "oci" {
  region = var.region
}

provider "oci" {
alias = "home"
region = data.oci_identity_regions.home-region.regions[0]["name"]
}

data "oci_identity_tenancy" "tenancy" {
  tenancy_id = var.tenancy_ocid
}

data "oci_identity_regions" "home-region" {
  filter {
    name   = "key"
    values = [data.oci_identity_tenancy.tenancy.home_region_key]
  }
}

resource "oci_identity_dynamic_group" "this" {
  provider = oci.home
  compartment_id = var.tenancy_ocid
  name           = var.name
  description    = var.description
  matching_rule  = var.matching_rule
}