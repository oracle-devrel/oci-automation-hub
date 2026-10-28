# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "compartment_ocid" {
  description = "OCID of the compartment where the log group will be created."
  type        = string
}

variable "display_name" {
  description = "Display name for the log group and Logs. Must be unique within the compartment."
  type        = string
}

variable "description" {
  description = "Optional description for the log group."
  type        = string
  default     = null
}

variable "defined_tags" {
  description = "Optional defined tags for the log group."
  type        = map(string)
  default     = null
}

variable "freeform_tags" {
  description = "Optional freeform tags for the log group."
  type        = map(string)
  default     = null
}