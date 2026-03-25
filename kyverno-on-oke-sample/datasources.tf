# Copyright (c) 2022, 2024 Oracle Corporation and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

data "oci_identity_tenancy" "tenant_details" {

  tenancy_id = var.tenancy_ocid
}

data "oci_identity_regions" "home_region" {

  filter {
    name   = "key"
    values = [data.oci_identity_tenancy.tenant_details.home_region_key]
  }
}