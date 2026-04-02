# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "compartment_ocid" {
  type = string
}

variable "region1" {
  type = string
}

variable "region2" {
  type = string 
}

variable "vcn_params_region1" {
  description = "VCN Parameters: vcn_cidr, display_name, dns_label"
  type = map(object({
    vcn_cidr         = string
    display_name     = string
    dns_label        = string
  }))
}

variable "igw_params_region1" {
  description = "Placeholder for vcn index association and igw name"
  type = map(object({
    vcn_name     = string
    display_name = string
  }))
}

variable "ngw_params_region1" {
  description = "Placeholder for vcn index association and ngw name"
  type = map(object({
    vcn_name     = string
    display_name = string
  }))
}

variable "sgw_params_region1" {
  description = "Placeholder for vcn index association and ngw name"
  type = map(object({
    vcn_name     = string
    display_name = string
    service_name = string
  }))
}

variable "rt_params_region1" {
  description = "Placeholder for vcn index association, rt name, route rules"
  type = map(object({
    vcn_name     = string
    display_name = string
    route_rules = list(object({
      destination = string
      use_igw     = bool
      igw_name    = string
      use_sgw     = bool
      sgw_name    = string
      ngw_name    = string
    }))
  }))
}


variable "subnet_params_region1" {
  type = map(object({
    display_name      = string
    cidr_block        = string
    dns_label         = string
    is_subnet_private = bool
    sl_name           = string
    rt_name           = string
    vcn_name          = string
  }))
}

variable "sl_params_region1" {
  description = "Security List Params"
  type = map(object({
    vcn_name     = string
    display_name = string
    egress_rules = list(object({
      stateless        = string
      protocol         = string
      destination      = string
      destination_type = optional(string, "CIDR_BLOCK")
    }))
    ingress_rules = list(object({
      stateless   = string
      protocol    = string
      source      = string
      source_type = string
      tcp_options = list(object({
        min = number
        max = number
      }))
      udp_options = list(object({
        min = number
        max = number
      }))
    }))
  }))
}

variable "drg_params_region1" {
  type = map(object({
    name     = string
    vcn_name = string
  }))
}

variable "drg_attachment_params_region1" {
  type = map(object({
    drg_name = string
    vcn_name = string
    cidr_rt  = list(string)
    rt_names = list(string)
  }))
}

### VCN Region 2
variable "vcn_params_region2" {
  description = "VCN Parameters: vcn_cidr, display_name, dns_label"
  type = map(object({
    vcn_cidr         = string
    display_name     = string
    dns_label        = string
  }))
}

variable "igw_params_region2" {
  description = "Placeholder for vcn index association and igw name"
  type = map(object({
    vcn_name     = string
    display_name = string
  }))
}

variable "ngw_params_region2" {
  description = "Placeholder for vcn index association and ngw name"
  type = map(object({
    vcn_name     = string
    display_name = string
  }))
}

variable "sgw_params_region2" {
  description = "Placeholder for vcn index association and ngw name"
  type = map(object({
    vcn_name     = string
    display_name = string
    service_name = string
  }))
}

variable "rt_params_region2" {
  description = "Placeholder for vcn index association, rt name, route rules"
  type = map(object({
    vcn_name     = string
    display_name = string
    route_rules = list(object({
      destination = string
      use_igw     = bool
      igw_name    = string
      use_sgw     = bool
      sgw_name    = string
      ngw_name    = string
    }))
  }))
}


variable "subnet_params_region2" {
  type = map(object({
    display_name      = string
    cidr_block        = string
    dns_label         = string
    is_subnet_private = bool
    sl_name           = string
    rt_name           = string
    vcn_name          = string
  }))
}

variable "sl_params_region2" {
  description = "Security List Params"
  type = map(object({
    vcn_name     = string
    display_name = string
    egress_rules = list(object({
      stateless        = string
      protocol         = string
      destination      = string
      destination_type = optional(string, "CIDR_BLOCK")
    }))
    ingress_rules = list(object({
      stateless   = string
      protocol    = string
      source      = string
      source_type = string
      tcp_options = list(object({
        min = number
        max = number
      }))
      udp_options = list(object({
        min = number
        max = number
      }))
    }))
  }))
}

variable "drg_params_region2" {
  type = map(object({
    name     = string
    vcn_name = string
  }))
}

variable "drg_attachment_params_region2" {
  type = map(object({
    drg_name = string
    vcn_name = string
    cidr_rt  = list(string)
    rt_names = list(string)
  }))
}

# Remote-peering
variable "requestor_params" {
  type = object({
    drg_name         = string
  })
}

variable "acceptor_params" {
  type = object({
    drg_name         = string
  })
}

# DNS region1
variable "dns_params_region1" {
  type = map(object({
    vcn_name         = string
    zone_name        = string
    zone_type        = optional(string, "PRIMARY")
    zone_scope       = any
    freeform_tags    = optional(map(string), {})
    dns_view         = optional(string, "DEFAULT")
  }))
}


# Instances
variable "linux_images" {
  type = map(map(string))
}

# Instances region1
variable "instance_params_region1" {
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
  }))
}

variable "bv_params_region1" {
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

# Instances region2
variable "instance_params_region2" {
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
  }))
}

variable "bv_params_region2" {
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