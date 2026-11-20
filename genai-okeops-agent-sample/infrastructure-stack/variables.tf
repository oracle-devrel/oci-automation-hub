# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

#############################
# OCI Provider Configuration
#############################

variable "region" {
  description = "OCI region where resources will be created."
  type        = string
}

variable "tenancy_ocid" {
  description = "OCI tenancy OCID. Can be supplied via TF_VAR_tenancy_ocid or environment."
  type        = string
}

variable "compartment_ocid" {
  description = "OCI compartment OCID where resources will be created. Can be supplied via TF_VAR_compartment_ocid or environment."
  type        = string
}

variable "display_name_prefix" {
  description = "Prefix for all the components deployed by the stack."
  type        = string
}

variable "component_description" {
  description = "Description for the components deployed by the stack."
  type        = string
}

#############################
# OKE Configuration
#############################
variable "availability_domain" {
  description = "Availability domain for the OKE worker nodes."
  type        = string
}

variable "vcn_id" {
  description = "Existing VCN with OKE endpoint/worker security rules and routing."
  type        = string
}

variable "oke_endpoint_subnet_id" {
  description = "Subnet for the Kubernetes API endpoint. Must be public when oke_public_endpoint is true."
  type        = string
}

variable "oke_worker_subnet_id" {
  description = "Worker subnet with outbound access to OCI services and container registries."
  type        = string
}

variable "oke_public_endpoint" {
  description = "Expose a public Kubernetes API endpoint; private endpoints require a runner with VCN access."
  type        = bool
  default     = true
}

variable "cluster_id" {
  description = "Optional OKE cluster OCID for the alarm. Defaults to the cluster created by this stack."
  type        = string
  default     = null
}

variable "kubernetes_version" {
  description = "OKE-supported Kubernetes version, including the v prefix (for example v1.34.1)."
  type        = string
}

variable "node_shape" {
  description = "OKE worker Flex shape compatible with the selected OKE image."
  type        = string
  default     = "VM.Standard.E4.Flex"
  validation {
    condition     = contains(["VM.Standard.E4.Flex", "VM.Standard.E5.Flex"], var.node_shape)
    error_message = "Select VM.Standard.E4.Flex or VM.Standard.E5.Flex."
  }
}

variable "node_image_id" {
  description = "OKE worker image OCID compatible with the Kubernetes version and node shape; use an OKE image, not a generic Oracle Linux image."
  type        = string
}

variable "node_count" {
  description = "Number of managed worker nodes (2 OCPUs and 16 GB RAM each)."
  type        = number
  default     = 1
  validation {
    condition     = var.node_count >= 1 && floor(var.node_count) == var.node_count
    error_message = "node_count must be a positive integer."
  }
}

variable "ssh_public_keys" {
  description = "Optional SSH public key for OKE worker nodes."
  type        = string
  default     = ""
}

variable "kubernetes_cli_auth" {
  description = "OCI CLI authentication for Kubernetes: resource_principal in Resource Manager, api_key for local CLI credentials."
  type        = string
  default     = "resource_principal"
  validation {
    condition     = contains(["resource_principal", "api_key", "instance_principal", "security_token"], var.kubernetes_cli_auth)
    error_message = "Use a supported OCI CLI authentication mode."
  }
}

#############################
# Tagging (Optional)
#############################

variable "tags" {
  description = "Defined and freeform tags for resources."
  type = object({
    definedTags  = optional(map(string))
    freeformTags = optional(map(string))
  })
  default = {}
}
variable "kubernetes_api_client_cidrs" {
  description = "IPv4 CIDRs allowed to access the Kubernetes API, such as the Terraform runner public IP /32."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for cidr in var.kubernetes_api_client_cidrs : can(cidrnetmask(cidr))])
    error_message = "Supply valid IPv4 CIDR blocks."
  }
}

variable "mcp_subnet_id" {
  description = "MCP subnet allowed to access the Kubernetes API. Defaults to the worker subnet used by the sample."
  type        = string
  default     = null
}
