# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "tenancy_ocid" {
  description = "OCI tenancy OCID, used to look up the Object Storage namespace."
  type        = string
}

variable "compartment_ocid" {
  description = "OCI compartment OCID where the bucket, knowledge base, data source, agent, and tool will be created."
  type        = string
}

variable "display_name_prefix" {
  description = "Prefix for all components deployed in the stack."
  type = string
}
variable "component_description" {
    description = "Description for all components deployed in the stack."
    type = string
}

variable "bucket_access_type" {
  description = "Bucket access type."
  type        = string
  default     = "NoPublicAccess"
}

variable "kb_file_path" {
  description = "Path to the knowledge base file."
  type = string
}

variable "knowledge_base_should_enable_hybrid_search" {
  description = "Enable hybrid search on the service-managed knowledge base index."
  type        = bool
  default     = true
}

variable "data_source_should_enable_multi_modality" {
  description = "Enable multi-modality during ingestion."
  type        = bool
  default     = false
}

variable "agent_welcome_message" {
  description = "Welcome message for the agent."
  type        = string
  default     = null
}