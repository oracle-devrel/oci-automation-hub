# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "name" {
  description = "Name of the stream."
  type        = string
}

variable "partitions" {
  description = "Number of partitions for the stream."
  type        = number
  default     = 1
  
}

variable "compartment_ocid" {
  description = "OCID of the compartment that will contain the stream."
  type        = string
}