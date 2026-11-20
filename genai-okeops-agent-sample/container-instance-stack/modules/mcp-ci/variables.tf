# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "tenancy_ocid" {
  description = "OCI tenancy OCID (used only for provider configuration if needed)."
  type        = string
}

variable "region" {
  description = "OCI region identifier, for example us-ashburn-1."
  type        = string
}

variable "compartment_id" {
  description = "Compartment OCID in which to create the container instance."
  type        = string
}

variable "availability_domain" {
  description = "Availability domain where the container instance will run."
  type        = string
}

variable "container_instance_display_name" {
  description = "Display name for the container instance."
  type        = string
}

variable "container_image_url" {
  description = "Container image URL, for example iad.ocir.io/namespace/repo:tag or docker.io/library/nginx:latest."
  type        = string
}

variable "container_display_name" {
  description = "Display name for the container inside the instance."
  type        = string
}

variable "rag_agent_endpoint_id" {
  type        = string
  description = "Agent Endpoint OCID for the RAG agent to connect to."

}

variable "shape" {
  description = "Container instance shape. Use a flexible shape supported by Container Instances."
  type        = string
  default     = "CI.Standard.E4.Flex"
}

variable "ocpus" {
  description = "Number of OCPUs to allocate to the container instance."
  type        = number
}

variable "memory_in_gbs" {
  description = "Amount of memory in GB to allocate to the container instance."
  type        = number
}

variable "subnet_id" {
  description = "Subnet OCID for the container instance VNIC."
  type        = string
}

variable "assign_public_ip" {
  description = "Whether to assign a public IP to the container instance VNIC."
  type        = bool
}
variable "nsg_ids" {
  description = "Network security groups attached to this component."
  type        = list(string)
  default     = []
}
