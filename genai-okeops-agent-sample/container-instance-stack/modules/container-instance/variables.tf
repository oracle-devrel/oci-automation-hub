# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "compartment_id" {
  description = "Compartment OCID where the Container Instance is created."
  type        = string
}

variable "availability_domain" {
  description = "Availability domain name."
  type        = string
}

variable "subnet_id" {
  description = "Subnet OCID for the Container Instance VNIC."
  type        = string
}

variable "app_name" {
  description = "Base application name."
  type        = string
}

variable "image_url" {
  description = "Full container image URL to deploy."
  type        = string
}

variable "image_version" {
  description = "Image version label used for naming and tags."
  type        = string
}

variable "app_base_url" {
  description = "Public URL used by the app and OIDC callback."
  type        = string
}

variable "identity_domain_issuer" {
  description = "OCI Identity Domain issuer URL."
  type        = string
}

variable "oidc_client_id" {
  description = "OIDC client ID."
  type        = string
}

variable "oidc_client_secret" {
  description = "OIDC client secret."
  type        = string
  sensitive   = true
}

variable "ocpus" {
  description = "Number of OCPUs to allocate to the container instance."
  type        = number
}

variable "memory_in_gbs" {
  description = "Amount of memory in GB to allocate to the container instance."
  type        = number
}

variable "assign_public_ip" {
  description = "Whether to assign a public IP to the container instance VNIC."
  type        = bool
}
variable "shape" {
  description = "Container instance shape. Use a flexible shape supported by Container Instances."
  type        = string
}
variable "nsg_ids" {
  description = "Network security groups attached to this component."
  type        = list(string)
  default     = []
}
