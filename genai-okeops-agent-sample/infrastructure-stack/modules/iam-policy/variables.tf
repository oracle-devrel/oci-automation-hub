# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "compartment_ocid" {
  description = "OCI compartment OCID where resources will be created. This is used in the policy statements."
  type        = string
  
}

variable "display_name" {
  description = "IAM policy name."
  type        = string
}

variable "description" {
  description = "IAM policy description."
  type        = string
}

variable "statements" {
  description = "Statements for the IAM Policy."
  type = list(string)
  
}

variable "region" {
  description = "OCI region where the IAM policy will be created."
  type        = string
}

variable "tenancy_ocid" {
  description = "value"
}