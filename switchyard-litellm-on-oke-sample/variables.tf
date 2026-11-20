# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# ORM Variables
variable "compartment_ocid" {}

variable "region" {}

variable "tenancy_ocid" {}

variable "oci_auth_mode" {
  description = "Use an OCI configuration profile or explicit API signing key details."
  type        = string
  default     = "profile"

  validation {
    condition     = contains(["profile", "explicit"], var.oci_auth_mode)
    error_message = "oci_auth_mode must be profile or explicit."
  }
}

variable "oci_config_profile" {
  description = "Profile in ~/.oci/config, used when oci_auth_mode is profile."
  type        = string
  default     = "DEFAULT"
}

variable "oci_user_ocid" {
  description = "OCI user OCID for explicit authentication."
  type        = string
  default     = null
}

variable "oci_fingerprint" {
  description = "API signing key fingerprint for explicit authentication."
  type        = string
  default     = null
}

variable "oci_private_key_path" {
  description = "Local API signing private key path for explicit authentication."
  type        = string
  default     = null
}

variable "oci_private_key_password" {
  description = "Optional API signing key passphrase; supply only in the private terminal."
  type        = string
  default     = null
  sensitive   = true
}

# OKE Module Variables
variable "bastion_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "bastion_image_os" {
  type    = string
  default = "Oracle Linux"
}

variable "bastion_image_os_version" {
  type    = string
  default = "8"
}

variable "bastion_image_type" {
  type    = string
  default = "platform"

  validation {
    condition     = contains(["platform", "custom"], var.bastion_image_type)
    error_message = "The bastion_image_type can be only `platform` or `custom`."
  }
}

variable "bastion_image_id" {
  type    = string
  default = null
}

variable "bastion_user" {
  type    = string
  default = "opc"
}

variable "cidr_vcn" {
  type    = string
  default = "10.0.0.0/16"
}

variable "cidr_bastion_subnet" {
  type    = string
  default = "10.0.0.0/29"
}

variable "cidr_operator_subnet" {
  type    = string
  default = "10.0.0.64/29"
}

variable "cidr_cp_subnet" {
  type    = string
  default = "10.0.0.8/29"
}

variable "cidr_int_lb_subnet" {
  type    = string
  default = "10.0.0.32/27"
}

variable "cidr_pub_lb_subnet" {
  type    = string
  default = "10.0.128.0/27"
}

variable "cidr_workers_subnet" {
  type    = string
  default = "10.0.144.0/20"
}

variable "cidr_pods_subnet" {
  type    = string
  default = "10.0.64.0/18"
}

variable "cluster_name" {
  type    = string
  default = "oke"
}

variable "cni_type" {
  type    = string
  default = "npn"

  validation {
    condition     = contains(["flannel", "npn"], var.cni_type)
    error_message = "The cni_type can be only `flannel` or `npn`."
  }
}

variable "compartment_id" {
  type    = string
  default = null
}

variable "control_plane_is_public" {
  type    = bool
  default = false
}

variable "control_plane_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "create_cluster" {
  type    = bool
  default = true
}

variable "create_iam_resources" {
  type    = bool
  default = false
}

variable "create_iam_defined_tags" {
  type    = bool
  default = false
}

variable "create_iam_tag_namespace" {
  type    = bool
  default = false
}

variable "create_operator" {
  type    = bool
  default = true
}

variable "create_bastion" {
  type    = bool
  default = true
}

variable "create_vcn" {
  type    = bool
  default = true
}

variable "gpu_np_size" {
  type    = number
  default = 0
}

variable "gpu_np_shape" {
  type    = string
  default = "VM.GPU.A10.1"
}

variable "kubernetes_version" {
  type    = string
  default = "v1.36.4"
}

variable "operator_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "operator_image_os" {
  type    = string
  default = "Oracle Linux"
}

variable "operator_image_os_version" {
  type    = string
  default = "8"
}

variable "operator_image_type" {
  type    = string
  default = "platform"

  validation {
    condition     = contains(["platform", "custom"], var.operator_image_type)
    error_message = "The operator_image_type can be only `platform` or `custom`."
  }
}

variable "operator_image_id" {
  type    = string
  default = null
}

variable "operator_user" {
  type    = string
  default = "opc"
}

variable "general_np_flex_shape" {
  type = map(any)
  default = {
    "instanceShape" = "VM.Standard.E5.Flex"
    "ocpus"         = 2
    "memory"        = 16
  }
}

variable "general_np_size" {
  type    = number
  default = 1
}

variable "ssh_public_key" {
  type    = string
  default = ""
}

variable "state_id" {
  default     = "ocidemo"
  description = "Optional Terraform state_id from an existing deployment of the module to re-use with created resources."
  type        = string
}

variable "tag_namespace" {
  type    = string
  default = "oke"
}

variable "use_defined_tags" {
  type    = bool
  default = false
}

variable "vcn_id" {
  type    = string
  default = null
}

variable "vcn_name" {
  type    = string
  default = "oke-vcn"
}

variable "nvidia_api_key" {
  type      = string
  sensitive = true
}

variable "ocir_username" {
  type = string
}

variable "ocir_auth_token" {
  type      = string
  sensitive = true
}
