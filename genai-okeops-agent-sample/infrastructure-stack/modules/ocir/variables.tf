# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "compartment_ocid" {
  description = "OCID of the compartment where the container repository will be created."
  type        = string
}

variable "display_name" {
  description = "Name of the container repository to create."
  type        = string
}

variable "is_public" {
  description = "Whether the repository is public."
  type        = bool
  default     = false
}

variable "is_immutable" {
  description = "Whether the repository should be immutable."
  type        = bool
  default     = false
}

variable "readme_content" {
  description = "Optional repository README content."
  type        = string
  default     = null
}