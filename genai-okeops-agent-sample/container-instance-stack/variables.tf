# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "tenancy_ocid" {
  description = "OCI Tenancy OCID."
  type        = string
}
variable "identity_domain_ocid" {
  description = "OCI Identity Domain OCID, for example ocid1.identity.oc1..aaaaaaaamjlz5jgh7uspm7h6cppdgrmlj76r7232737dsom4flwq2m4w723a."
  type        = string
}
variable "mcp_container_image_url" {
  description = "Container image URL for the MCP server instance, for example iad.ocir.io/namespace/repository:tag."
  type        = string
}
variable "rag_agent_endpoint_id" {
  description = "Agent Endpoint OCID for the RAG agent to connect to."
  type        = string
}
variable "shape" {
  description = "Container instance shape. Use a flexible shape supported by Container Instances."
  type        = string
}
variable "ocpus" {
  description = "Number of OCPUs to allocate to the container instance."
  type        = number
}
variable "memory_in_gbs" {
  description = "Amount of memory in GB to allocate to the container instance."
  type        = number
}

variable "region" {
  description = "OCI region where the resources will be deployed."
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment OCID where resources will be created."
  type        = string
}

variable "availability_domain" {
  description = "Availability domain name, for example liOm:US-ASHBURN-AD-1."
  type        = string
}

variable "lb_subnet_id" {
  description = "Public subnet OCID used by the load balancer and Container Instance VNIC."
  type        = string
}

variable "app_subnet_id" {
  description = "Subnet OCID used by the application Container Instance VNIC."
  type        = string
}

variable "app_name_prefix" {
  description = "Base name used for deployed OCI resources."
  type        = string
}

variable "app_image_url" {
  description = "Full container image URL to deploy, for example iad.ocir.io/namespace/repository:tag."
  type        = string
}
variable "assign_public_ip" {
  description = "Whether to assign a public IP to the application container instance VNIC."
  type        = bool
  default     = false
}
variable "app_client_cidrs" {
  description = "IPv4 CIDRs allowed to access the application HTTPS listener."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for cidr in var.app_client_cidrs : can(cidrnetmask(cidr))])
    error_message = "Supply valid IPv4 CIDR blocks."
  }
}
