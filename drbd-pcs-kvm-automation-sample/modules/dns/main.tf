# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

terraform {
  required_providers {
    oci = {
      source   = "hashicorp/oci"
      version  = "7.25.0"
    }
  }
}

resource "oci_dns_view" "this" {
  for_each       = var.dns_params
  compartment_id = var.compartment_id
  scope          = each.value.zone_scope
  display_name   = each.value.dns_view_name == "" ? format("%s-custom", each.value.vcn_name) : each.value.view_display_name
  freeform_tags  = each.value.freeform_tags
}

resource "oci_dns_zone" "this" {
  for_each       = var.dns_params
  compartment_id = var.compartment_id
  name           = each.value.zone_name
  zone_type      = each.value.zone_type
  freeform_tags  = each.value.freeform_tags
  scope          = each.value.zone_scope
  view_id        = oci_dns_view.this[each.key].id
}

data "oci_dns_resolvers" "this" {
  for_each       = var.dns_params
  compartment_id = var.compartment_id
  scope          = each.value.zone_scope
  display_name   = each.value.vcn_name
  state          = each.value.resolver_state
}

resource "oci_dns_resolver" "this" {
  for_each    = var.dns_params
  resolver_id = element(data.oci_dns_resolvers.this[each.key].resolvers, 0).id
  attached_views {
    view_id = oci_dns_view.this[each.key].id
  }
}
