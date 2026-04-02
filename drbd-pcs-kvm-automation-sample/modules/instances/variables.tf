# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "compartment_id" {
  type = string
}

variable "subnet_ids" {
  type = map(string)
}

variable "region" {
  type = string
}

variable "linux_images" {
  type = map(map(string))
}

variable "nsgs" {
  type    = map(string)
  default = {}
}

variable "instance_params" {
  description = "Placeholder for the parameters of the instances"
  type = map(object({
    ad                        = number
    shape                     = optional(string, "VM.Standard.E6.Flex")
    hostname                  = string
    boot_volume_size          = optional(number, 50)
    assign_public_ip          = bool
    preserve_boot_volume      = optional(bool, false)
    subnet_name               = string
    device_disk_mappings      = string
    freeform_tags             = optional(map(string), {})
    kms_key_name              = optional(string, "")
    block_vol_att_type        = string
    encrypt_in_transit        = bool
    fd                        = number
    image_version             = string
    nsgs                      = optional(list(string), [])
    ocpus                     = optional(number, 1)
    memory_in_gbs             = optional(number, 8)
    baseline_ocpu_utilization = optional(string, "BASELINE_1_1")
    are_legacy_imds_endpoints_disabled = optional(bool, true)
  }))
}

variable "bv_params" {
  description = "Placeholder the bv parameters"
  type = map(object({
    ad                 = number
    display_name       = string
    bv_size            = number
    instance_name      = string
    device_name        = string
    freeform_tags      = optional(map(string), {})
    kms_key_name       = string
    vpus_per_gb        = string
    encrypt_in_transit = bool
  }))
}

variable "kms_key_ids" {
  type    = map(string)
  default = {}
}


variable ssh_public_key {
  description = "Public SSH key for the stack"
  type        = string
}