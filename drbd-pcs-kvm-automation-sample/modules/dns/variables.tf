# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "compartment_id" {
  type = string
}

variable "dns_params" {
  type = map(object({
    vcn_name         = string
    zone_name        = string
    zone_type        = optional(string, "PRIMARY")
    zone_scope       = any
    freeform_tags    = optional(map(string), {})
    dns_view         = optional(string, "DEFAULT")
    resolver_state   = optional(string, "ACTIVE")
    dns_view_name    = optional(string, "")
  }))
}
