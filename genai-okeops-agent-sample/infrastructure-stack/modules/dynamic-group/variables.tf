# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "tenancy_ocid" {
  description = "OCI Tenancy Id, the Dynamic Group will be created at the tenancy level."
  type = string
}
variable "region" {
  description = "OCI Region where the Dynamic Group will be created."
  type = string
}

variable "name" {
  description = "Dynamic group name. Must be unique across the tenancy and cannot be changed later."
  type        = string
}

variable "description" {
  description = "Dynamic group description."
  type        = string
}

variable "matching_rule" {
  description = "Matching rule that defines which resources belong to the dynamic group."
  type        = string
}