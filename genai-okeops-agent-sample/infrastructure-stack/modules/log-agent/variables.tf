# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "compartment_ocid" {
  description = "OCID of the compartment that contains the unified agent configuration."
  type        = string
}

variable "display_name" {
  description = "Display name for the unified agent configuration."
  type        = string
}

variable "description" {
  description = "Description for the unified agent configuration."
  type        = string
}

variable "is_enabled" {
  description = "Whether the configuration is enabled."
  type        = bool
  default     = true
}

variable "group_list" {
  description = "List of dynamic group OCIDs associated with this configuration."
  type        = list(string)
  default     = []
}

variable "log_object_id" {
  description = "OCID of the destination log."
  type        = string
}

variable "paths" {
  description = "Absolute paths for log source files."
  type        = list(string)
}

variable "source_name" {
  description = "Name of the log source."
  type        = string
  default     = "logs"
}

variable "parser_type" {
  description = "Parser type for the log source."
  type        = string
  default     = "NONE"
}

variable "message_key" {
  description = "Message key for parser_type = NONE."
  type        = string
  default     = "message"
}

variable "defined_tags" {
  description = "Optional defined tags."
  type        = map(string)
  default     = null
}

variable "freeform_tags" {
  description = "Optional free-form tags."
  type        = map(string)
  default     = null
}