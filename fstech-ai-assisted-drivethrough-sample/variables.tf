# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "tenancy_ocid" {
  description = "OCI tenancy OCID."
  type        = string
}

variable "compartment_ocid" {
  description = "OCI parent compartment OCID. Terraform creates Network, Data, AI, and Application child compartments beneath it."
  type        = string
}

variable "region" {
  description = "OCI deployment region. GenAI Agents, ADB 26ai, Vision, and Speech must be available in this region."
  type        = string
}

variable "provider_auth" {
  description = "Optional OCI provider auth override. Leave empty for Resource Manager or the local provider default."
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Lowercase prefix used for resource names."
  type        = string
  default     = "fstech"
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,12}$", var.name_prefix))
    error_message = "name_prefix must be 3-13 lowercase alphanumeric characters."
  }
}

variable "create_genai_agent" {
  description = "Create a new GenAI Agent and endpoint. Set false to reuse an existing endpoint when the agent-count limit is exhausted."
  type        = bool
  default     = true
}

variable "existing_agent_endpoint_id" {
  description = "Existing GenAI Agent endpoint OCID used when create_genai_agent is false."
  type        = string
  default     = ""
}

variable "existing_agent_id" {
  description = "Parent Agent OCID of the reused endpoint. Terraform attaches the six function tools to this Agent."
  type        = string
  default     = ""
}

variable "existing_agent_compartment_ocid" {
  description = "Compartment OCID containing the reused endpoint, required when create_genai_agent is false."
  type        = string
  default     = ""
}

variable "adb_compute_count" {
  description = "Autonomous AI Database ECPU count."
  type        = number
  default     = 2
}

variable "vm_shape" {
  description = "Flexible compute shape used for the web application."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "vm_ocpus" {
  type    = number
  default = 2
}

variable "vm_memory_gbs" {
  type    = number
  default = 16
}

variable "ssh_public_key" {
  description = "Optional SSH public key for troubleshooting the runtime VM."
  type        = string
  default     = ""
}

variable "use_existing_network" {
  description = "Use an existing VCN and public subnet instead of creating a dedicated VCN."
  type        = bool
}

variable "existing_network_compartment_ocid" {
  description = "Compartment containing the existing VCN and subnet. Required when use_existing_network is true."
  type        = string
  default     = ""
}

variable "existing_vcn_id" {
  description = "Existing VCN OCID. Required when use_existing_network is true."
  type        = string
  default     = ""
}

variable "existing_subnet_id" {
  description = "Existing public subnet OCID. It must belong to existing_vcn_id, permit public IPs, and route to an Internet Gateway."
  type        = string
  default     = ""
}

variable "new_vcn_cidr" {
  description = "CIDR for a newly created VCN. Required when use_existing_network is false."
  type        = string
  default     = ""
}

variable "new_subnet_cidr" {
  description = "CIDR for the new public subnet. It must be contained by new_vcn_cidr."
  type        = string
  default     = ""
}

variable "tts_voice_id" {
  type    = string
  default = "Victoria"
}

variable "freeform_tags" {
  type    = map(string)
  default = { Application = "FSTechDriveThru" }
}
