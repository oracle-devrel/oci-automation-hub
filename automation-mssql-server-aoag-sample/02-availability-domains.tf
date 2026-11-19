# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
data "oci_identity_availability_domains" "region" {
  compartment_id = var.compartment_id
}

locals {
  # OCI regions can expose one or several ADs. Sorting makes AD-1/AD-2
  # selection deterministic because OCI does not guarantee API result order.
  available_availability_domains = sort([
    for availability_domain in data.oci_identity_availability_domains.region.availability_domains : availability_domain.name
  ])

  selected_dc_availability_domain   = var.dc_availability_domain != "" ? var.dc_availability_domain : local.available_availability_domains[0]
  selected_sql1_availability_domain = var.sql1_availability_domain != "" ? var.sql1_availability_domain : local.available_availability_domains[0]
  selected_sql2_availability_domain = var.sql2_availability_domain != "" ? var.sql2_availability_domain : try(local.available_availability_domains[1], local.available_availability_domains[0])
}
