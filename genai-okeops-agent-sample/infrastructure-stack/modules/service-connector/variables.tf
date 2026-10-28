# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "compartment_ocid" {
  description = "OCID of the compartment that will contain the service connector."
  type        = string
}

variable "display_name" {
  description = "Display name for the service connector."
  type        = string
}

variable "description" {
  description = "Description for the service connector."
  type        = string
  default     = null
}

variable "source_log_group_id" {
  description = "OCID of the log group containing the source logs."
  type        = string
}

variable "log_id" {
  description = "OCID for the source logs"
  type        = string
}

variable "target_stream_id" {
  description = "OCID of the target stream."
  type        = string
}