# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "instances_region1" {
  type = any
}

variable "instances_region2" {
  type = any
}

variable "private_ssh_key_path" {
  type = string
}

variable "dns_zones" {
  type = map(any)
}

variable "pcs_drbd_dns_details" {
  type = object({
    dns_object_name        = string
    dns_record_name        = optional(string, "primary")
    dns_region             = string
    dns_unregister_on_stop = optional(bool, false)
  })
}

variable "linbit_username" {
  type      = string
  sensitive = true
}

variable "linbit_password" {
  type      = string
  sensitive = true
}

variable "linbit_cluster_id" {
  type = string
  sensitive = true
}

variable "pcs_password" {
  type      = string
  sensitive = true
}
